package uk.co.actionnotes.actionnotes

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.provider.DocumentsContract
import android.provider.DocumentsContract.Document
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/**
 * Hosts the app, and gives the Dart side access to a folder the person picked
 * with the system folder picker.
 *
 * A notebook can live in a folder that OneDrive, Google Drive or Dropbox keeps
 * in step. On Android such a folder is not a path the app can open: it is a
 * document tree that a provider hands out access to, and the only way to reach
 * it is the Storage Access Framework. This is a deliberately small bridge onto
 * it — list, read, write, delete, make a folder — keyed by the tree's address
 * plus a path relative to it, which is the same shape the desktop folder
 * backend has. It needs no permission in the manifest: the person's choice in
 * the picker is the permission.
 */
class MainActivity : FlutterActivity() {
    private var pendingPick: MethodChannel.Result? = null

    // One thread, in order. Providers can be slow (a cloud app may download a
    // file to answer a read) and must never be waited on from the UI thread.
    private val io = Executors.newSingleThreadExecutor()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result -> handle(call, result) }
    }

    override fun onDestroy() {
        io.shutdown()
        super.onDestroy()
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        if (call.method == "pick") {
            pick(result)
            return
        }

        val tree = call.argument<String>("tree")?.let { Uri.parse(it) }
        if (tree == null) {
            result.error("failed", "No folder was given.", null)
            return
        }
        val path = call.argument<String>("path") ?: ""

        io.execute {
            try {
                val value: Any? = when (call.method) {
                    "exists" -> exists(tree)
                    "list" -> list(tree, path)
                    "read" -> read(tree, path)
                    "write" -> {
                        write(tree, path, call.argument<ByteArray>("bytes") ?: ByteArray(0))
                        null
                    }
                    "delete" -> delete(tree, path)
                    "mkdir" -> {
                        ensureDirectory(tree, segments(path))
                        null
                    }
                    else -> NOT_IMPLEMENTED
                }
                runOnUiThread {
                    if (value === NOT_IMPLEMENTED) result.notImplemented() else result.success(value)
                }
            } catch (e: SecurityException) {
                // Access was revoked, or the provider was uninstalled.
                runOnUiThread { result.error("denied", e.message, null) }
            } catch (e: Exception) {
                runOnUiThread { result.error("failed", e.message ?: e.toString(), null) }
            }
        }
    }

    // ---- Picking -------------------------------------------------------

    @Suppress("DEPRECATION")
    private fun pick(result: MethodChannel.Result) {
        if (pendingPick != null) {
            result.error("busy", "A folder is already being picked.", null)
            return
        }
        pendingPick = result

        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
            addFlags(
                Intent.FLAG_GRANT_READ_URI_PERMISSION or
                    Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                    Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION or
                    Intent.FLAG_GRANT_PREFIX_URI_PERMISSION
            )
        }
        startActivityForResult(intent, PICK_REQUEST)
    }

    @Suppress("DEPRECATION")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode != PICK_REQUEST) {
            super.onActivityResult(requestCode, resultCode, data)
            return
        }

        val result = pendingPick
        pendingPick = null
        val uri = data?.data
        if (result == null) return
        if (resultCode != Activity.RESULT_OK || uri == null) {
            result.success(null)
            return
        }

        try {
            // Kept across restarts. Without this the grant lasts until the
            // app is closed, and the notebook would be gone from the list
            // every time the phone was restarted.
            contentResolver.takePersistableUriPermission(
                uri,
                Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
            )
        } catch (e: SecurityException) {
            result.error("denied", "That folder cannot be kept: ${e.message}", null)
            return
        }

        io.execute {
            val name = try {
                queryOne(uri, DocumentsContract.getTreeDocumentId(uri), Document.COLUMN_DISPLAY_NAME)
            } catch (e: Exception) {
                null
            }
            runOnUiThread {
                result.success(mapOf("uri" to uri.toString(), "name" to (name ?: "")))
            }
        }
    }

    // ---- Document tree -------------------------------------------------

    private fun segments(path: String): List<String> =
        path.split('/').filter { it.isNotEmpty() && it != "." }

    private fun documentUri(tree: Uri, documentId: String): Uri =
        DocumentsContract.buildDocumentUriUsingTree(tree, documentId)

    private class Child(val id: String, val name: String, val isDirectory: Boolean, val size: Long, val modified: Long)

    private fun children(tree: Uri, parentId: String): List<Child> {
        val uri = DocumentsContract.buildChildDocumentsUriUsingTree(tree, parentId)
        val columns = arrayOf(
            Document.COLUMN_DOCUMENT_ID,
            Document.COLUMN_DISPLAY_NAME,
            Document.COLUMN_MIME_TYPE,
            Document.COLUMN_SIZE,
            Document.COLUMN_LAST_MODIFIED
        )
        val found = ArrayList<Child>()
        contentResolver.query(uri, columns, null, null, null)?.use { cursor ->
            while (cursor.moveToNext()) {
                found.add(
                    Child(
                        id = cursor.getString(0),
                        name = cursor.getString(1) ?: "",
                        isDirectory = cursor.getString(2) == Document.MIME_TYPE_DIR,
                        size = if (cursor.isNull(3)) 0L else cursor.getLong(3),
                        modified = if (cursor.isNull(4)) 0L else cursor.getLong(4)
                    )
                )
            }
        }
        return found
    }

    private fun queryOne(tree: Uri, documentId: String, column: String): String? {
        val uri = documentUri(tree, documentId)
        contentResolver.query(uri, arrayOf(column), null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) return cursor.getString(0)
        }
        return null
    }

    /** The document at a path, or null when any step of it is missing. */
    private fun resolve(tree: Uri, path: String): Child? {
        var current = Child(DocumentsContract.getTreeDocumentId(tree), "", true, 0L, 0L)
        for (name in segments(path)) {
            if (!current.isDirectory) return null
            current = children(tree, current.id).firstOrNull { it.name == name } ?: return null
        }
        return current
    }

    /** The folder at the end of [names], making whichever steps are missing. */
    private fun ensureDirectory(tree: Uri, names: List<String>): Child {
        var current = Child(DocumentsContract.getTreeDocumentId(tree), "", true, 0L, 0L)
        for (name in names) {
            val existing = children(tree, current.id).firstOrNull { it.name == name }
            current = if (existing != null) {
                if (!existing.isDirectory) throw IllegalStateException("$name is a file, not a folder")
                existing
            } else {
                val created = DocumentsContract.createDocument(
                    contentResolver,
                    documentUri(tree, current.id),
                    Document.MIME_TYPE_DIR,
                    name
                ) ?: throw IllegalStateException("Could not make the folder $name")
                Child(DocumentsContract.getDocumentId(created), name, true, 0L, 0L)
            }
        }
        return current
    }

    private fun exists(tree: Uri): Boolean {
        val kept = contentResolver.persistedUriPermissions.any {
            it.uri == tree && it.isReadPermission && it.isWritePermission
        }
        if (!kept) return false
        return queryOne(tree, DocumentsContract.getTreeDocumentId(tree), Document.COLUMN_DOCUMENT_ID) != null
    }

    private fun list(tree: Uri, path: String): List<Map<String, Any>>? {
        val folder = resolve(tree, path) ?: return null
        if (!folder.isDirectory) return null
        return children(tree, folder.id).map {
            mapOf(
                "name" to it.name,
                "dir" to it.isDirectory,
                "size" to it.size,
                "modified" to it.modified
            )
        }
    }

    private fun read(tree: Uri, path: String): ByteArray? {
        val file = resolve(tree, path) ?: return null
        if (file.isDirectory) return null
        return contentResolver.openInputStream(documentUri(tree, file.id))?.use { it.readBytes() }
    }

    private fun write(tree: Uri, path: String, bytes: ByteArray) {
        val names = segments(path)
        if (names.isEmpty()) throw IllegalArgumentException("No file name given")
        val parent = ensureDirectory(tree, names.dropLast(1))
        val name = names.last()

        val existing = children(tree, parent.id).firstOrNull { it.name == name }
        if (existing != null) {
            if (existing.isDirectory) throw IllegalStateException("$name is a folder, not a file")
            val target = documentUri(tree, existing.id)
            try {
                // "wt" truncates, so a shorter file does not keep the tail of
                // the longer one it replaces.
                contentResolver.openOutputStream(target, "wt")?.use { it.write(bytes) }
                    ?: throw IllegalStateException("Could not open $name for writing")
                return
            } catch (e: SecurityException) {
                throw e
            } catch (e: Exception) {
                // Some providers will not truncate. Replacing the file is the
                // slower way to the same result.
                DocumentsContract.deleteDocument(contentResolver, target)
            }
        }

        // Opaque, so no provider decides a ".md" file ought to be called
        // something else.
        val created = DocumentsContract.createDocument(
            contentResolver,
            documentUri(tree, parent.id),
            "application/octet-stream",
            name
        ) ?: throw IllegalStateException("Could not create $name")
        contentResolver.openOutputStream(created, "wt")?.use { it.write(bytes) }
            ?: throw IllegalStateException("Could not open $name for writing")
    }

    private fun delete(tree: Uri, path: String): Boolean {
        val target = resolve(tree, path) ?: return false
        return DocumentsContract.deleteDocument(contentResolver, documentUri(tree, target.id))
    }

    companion object {
        private const val CHANNEL = "uk.co.actionnotes/folders"
        private const val PICK_REQUEST = 7301
        private val NOT_IMPLEMENTED = Any()
    }
}
