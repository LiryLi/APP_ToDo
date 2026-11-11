package com.liry.todo.locknote;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.RemoteInput;
import android.content.Context;
import android.content.Intent;
import android.graphics.drawable.Icon;

/** Owns the public lock-screen notification and its inline RemoteInput action. */
public final class NoteNotification {
    public static final String CHANNEL_ID = "lock_note_capture_v1";
    public static final int NOTIFICATION_ID = 4101;
    private static final int REQUEST_SAVE = 4102;

    private NoteNotification() {
    }

    public static void createChannel(Context context) {
        NotificationManager manager = context.getSystemService(NotificationManager.class);
        NotificationChannel channel = new NotificationChannel(
                CHANNEL_ID, "锁屏速记", NotificationManager.IMPORTANCE_HIGH);
        channel.setDescription("在锁屏通知中直接输入并保存速记");
        channel.setLockscreenVisibility(Notification.VISIBILITY_PUBLIC);
        channel.setShowBadge(false);
        manager.createNotificationChannel(channel);
    }

    public static void showQuickNote(Context context, String title, String text) {
        createChannel(context);
        RemoteInput remoteInput = new RemoteInput.Builder(SaveNoteReceiver.KEY_NOTE_TEXT)
                .setLabel("输入速记")
                .build();
        Intent saveIntent = new Intent(context, SaveNoteReceiver.class)
                .setAction(SaveNoteReceiver.ACTION_SAVE_NOTE);
        // Mutable is required: Android attaches the typed text to this PendingIntent.
        PendingIntent savePendingIntent = PendingIntent.getBroadcast(
                context, REQUEST_SAVE, saveIntent,
                PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_MUTABLE);
        Notification.Action saveAction = new Notification.Action.Builder(
                Icon.createWithResource(context, R.drawable.ic_stat_note),
                "保存速记", savePendingIntent)
                .addRemoteInput(remoteInput)
                .build();

        String actualTitle = title == null ? "锁屏速记" : title;
        String actualText = text == null ? "展开通知，在输入框写下内容并保存" : text;
        Notification notification = new Notification.Builder(context, CHANNEL_ID)
                .setSmallIcon(R.drawable.ic_stat_note)
                .setContentTitle(actualTitle)
                .setContentText(actualText)
                .setStyle(new Notification.BigTextStyle().bigText(actualText))
                .setVisibility(Notification.VISIBILITY_PUBLIC)
                .setCategory(Notification.CATEGORY_MESSAGE)
                .setPriority(Notification.PRIORITY_HIGH)
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .setShowWhen(false)
                .addAction(saveAction)
                .build();
        context.getSystemService(NotificationManager.class).notify(NOTIFICATION_ID, notification);
    }
}
