package com.liry.todo.locknote;

import android.app.RemoteInput;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.os.Bundle;
import android.util.Log;

/** Receives inline-reply text and commits it to the local SQLite database. */
public final class SaveNoteReceiver extends BroadcastReceiver {
    public static final String ACTION_SAVE_NOTE = "com.liry.todo.locknote.action.SAVE_NOTE";
    public static final String KEY_NOTE_TEXT = "note_text";
    private static final String TAG = "LockNoteReceiver";

    @Override
    public void onReceive(Context context, Intent intent) {
        if (intent == null || !ACTION_SAVE_NOTE.equals(intent.getAction())) {
            return;
        }
        Bundle results = RemoteInput.getResultsFromIntent(intent);
        if (results == null) {
            Log.w(TAG, "No RemoteInput results");
            return;
        }
        CharSequence raw = results.getCharSequence(KEY_NOTE_TEXT);
        String content = raw == null ? "" : raw.toString().trim();
        if (content.isEmpty()) {
            NoteNotification.showQuickNote(context, "还没有输入内容", "输入文字后再点保存");
            return;
        }
        try {
            long id = NoteDbHelper.getInstance(context).insertNote(
                    content, System.currentTimeMillis(), "lockscreen_remote_input");
            String preview = content.length() > 180 ? content.substring(0, 180) + "…" : content;
            NoteNotification.showQuickNote(context, "已保存 #" + id + " · 可继续速记", preview);
            Log.i(TAG, "Saved lock-screen note #" + id);
        } catch (RuntimeException error) {
            Log.e(TAG, "Failed to save note", error);
            NoteNotification.showQuickNote(context, "保存失败", error.getClass().getSimpleName());
        }
    }
}
