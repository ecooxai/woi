package dev.woi.woi;

import android.content.ContentProvider;
import android.content.ContentValues;
import android.database.Cursor;
import android.database.MatrixCursor;
import android.net.Uri;
import android.os.ParcelFileDescriptor;
import android.provider.OpenableColumns;
import java.io.File;
import java.io.FileNotFoundException;

/** Test APK only: one fixed synthetic PNG, read-only, with temporary clipboard URI grants. */
public final class SyntheticClipboardProvider extends ContentProvider {
    @Override public boolean onCreate() { return true; }
    private File file(Uri uri) throws FileNotFoundException {
        if (!"/synthetic.png".equals(uri.getPath()) || getContext() == null) throw new FileNotFoundException("No fixture");
        File file = new File(getContext().getCacheDir(), ClipboardSnapshotActivity.FIXTURE_FILE);
        if (!file.isFile()) throw new FileNotFoundException("No fixture");
        return file;
    }
    @Override public String getType(Uri uri) { return "/synthetic.png".equals(uri.getPath()) ? "image/png" : null; }
    @Override public ParcelFileDescriptor openFile(Uri uri, String mode) throws FileNotFoundException {
        if (!"r".equals(mode)) throw new FileNotFoundException("Read-only fixture");
        return ParcelFileDescriptor.open(file(uri), ParcelFileDescriptor.MODE_READ_ONLY);
    }
    @Override public Cursor query(Uri uri, String[] projection, String selection, String[] selectionArgs, String sortOrder) {
        String[] names = projection == null ? new String[]{OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE} : projection;
        MatrixCursor cursor = new MatrixCursor(names);
        Object[] values = new Object[names.length];
        try {
            File file = file(uri);
            for (int i=0; i<names.length; i++) {
                if (OpenableColumns.DISPLAY_NAME.equals(names[i])) values[i] = "woi-qa-synthetic.png";
                else if (OpenableColumns.SIZE.equals(names[i])) values[i] = file.length();
            }
            cursor.addRow(values);
        } catch (FileNotFoundException ignored) { }
        return cursor;
    }
    @Override public Uri insert(Uri uri, ContentValues values) { throw new UnsupportedOperationException("Read-only fixture"); }
    @Override public int update(Uri uri, ContentValues values, String selection, String[] selectionArgs) { throw new UnsupportedOperationException("Read-only fixture"); }
    @Override public int delete(Uri uri, String selection, String[] selectionArgs) { throw new UnsupportedOperationException("Read-only fixture"); }
}
