package com.liry.todo.locknote;

import android.Manifest;
import android.app.Activity;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.os.Build;
import android.os.Bundle;
import android.provider.Settings;
import android.text.format.DateFormat;
import android.widget.TextView;
import java.util.Date;
import java.util.List;

public final class MainActivity extends Activity {
    private static final int REQUEST_NOTIFICATIONS = 100;
    private TextView statusText;
    private TextView notesText;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        setContentView(R.layout.activity_main);
        NoteNotification.createChannel(this);
        statusText = findViewById(R.id.statusText);
        notesText = findViewById(R.id.notesText);
        updateNotificationStatus();
    }

    @Override
    protected void onResume() {
        super.onResume();
        refreshNotes();
        updateNotificationStatus();
    }

    public void onPostNotification(android.view.View view) {
        if (Build.VERSION.SDK_INT >= 33
                && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS)
                != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(new String[]{Manifest.permission.POST_NOTIFICATIONS}, REQUEST_NOTIFICATIONS);
            return;
        }
        postNotification();
    }

    private void postNotification() {
        NoteNotification.showQuickNote(this, null, null);
        statusText.setText("通知已发送。现在锁屏，展开「锁屏速记」通知即可输入。");
    }

    public void onOpenNotificationSettings(android.view.View view) {
        Intent intent = new Intent(Settings.ACTION_CHANNEL_NOTIFICATION_SETTINGS)
                .putExtra(Settings.EXTRA_APP_PACKAGE, getPackageName())
                .putExtra(Settings.EXTRA_CHANNEL_ID, NoteNotification.CHANNEL_ID);
        startActivity(intent);
    }

    public void onRefresh(android.view.View view) {
        refreshNotes();
    }

    private void refreshNotes() {
        List<NoteDbHelper.Note> notes = NoteDbHelper.getInstance(this).getNotes();
        if (notes.isEmpty()) {
            notesText.setText("暂无记录。锁屏保存后可回到这里核对原文、时间和来源。");
            return;
        }
        StringBuilder output = new StringBuilder();
        for (NoteDbHelper.Note note : notes) {
            String time = DateFormat.format("yyyy-MM-dd HH:mm:ss", new Date(note.createdAt)).toString();
            output.append('#').append(note.id).append("  ").append(time).append('\n')
                    .append(note.content).append('\n')
                    .append("来源：").append(note.source).append("\n\n");
        }
        notesText.setText(output.toString().trim());
    }

    private void updateNotificationStatus() {
        NotificationManager manager = getSystemService(NotificationManager.class);
        NotificationChannel channel = manager.getNotificationChannel(NoteNotification.CHANNEL_ID);
        String visibility = channel.getLockscreenVisibility() == android.app.Notification.VISIBILITY_PUBLIC
                ? "渠道锁屏可见性：PUBLIC" : "渠道锁屏可见性：请检查设置";
        statusText.setText(visibility);
    }

    @Override
    public void onRequestPermissionsResult(int requestCode, String[] permissions, int[] grantResults) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults);
        if (requestCode == REQUEST_NOTIFICATIONS && grantResults.length > 0
                && grantResults[0] == PackageManager.PERMISSION_GRANTED) {
            postNotification();
        } else if (requestCode == REQUEST_NOTIFICATIONS) {
            statusText.setText("需要通知权限才能进行锁屏速记。");
        }
    }
}
