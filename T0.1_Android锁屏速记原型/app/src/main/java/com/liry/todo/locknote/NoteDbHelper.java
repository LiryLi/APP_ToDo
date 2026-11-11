package com.liry.todo.locknote;

import android.content.ContentValues;
import android.content.Context;
import android.database.Cursor;
import android.database.sqlite.SQLiteDatabase;
import android.database.sqlite.SQLiteOpenHelper;
import java.util.ArrayList;
import java.util.List;

/** Small local-only store. No network or account dependency. */
public final class NoteDbHelper extends SQLiteOpenHelper {
    private static final String DB_NAME = "lock_notes.db";
    private static final int DB_VERSION = 1;
    private static NoteDbHelper instance;

    public static final class Note {
        public final long id;
        public final String content;
        public final long createdAt;
        public final String source;

        Note(long id, String content, long createdAt, String source) {
            this.id = id;
            this.content = content;
            this.createdAt = createdAt;
            this.source = source;
        }
    }

    private NoteDbHelper(Context context) {
        super(context.getApplicationContext(), DB_NAME, null, DB_VERSION);
    }

    public static synchronized NoteDbHelper getInstance(Context context) {
        if (instance == null) {
            instance = new NoteDbHelper(context);
        }
        return instance;
    }

    @Override
    public void onCreate(SQLiteDatabase db) {
        db.execSQL("CREATE TABLE notes (" +
                "_id INTEGER PRIMARY KEY AUTOINCREMENT," +
                "content TEXT NOT NULL," +
                "created_at INTEGER NOT NULL," +
                "source TEXT NOT NULL," +
                "is_synced INTEGER NOT NULL DEFAULT 0)");
        db.execSQL("CREATE INDEX idx_notes_created_at ON notes(created_at DESC)");
    }

    @Override
    public void onUpgrade(SQLiteDatabase db, int oldVersion, int newVersion) {
        // Version 1: no upgrades yet.
    }

    public synchronized long insertNote(String content, long createdAt, String source) {
        ContentValues values = new ContentValues();
        values.put("content", content);
        values.put("created_at", createdAt);
        values.put("source", source);
        return getWritableDatabase().insertOrThrow("notes", null, values);
    }

    public synchronized List<Note> getNotes() {
        List<Note> notes = new ArrayList<>();
        Cursor cursor = getReadableDatabase().query(
                "notes", new String[]{"_id", "content", "created_at", "source"},
                null, null, null, null, "created_at DESC", "100");
        try {
            while (cursor.moveToNext()) {
                notes.add(new Note(cursor.getLong(0), cursor.getString(1),
                        cursor.getLong(2), cursor.getString(3)));
            }
        } finally {
            cursor.close();
        }
        return notes;
    }
}
