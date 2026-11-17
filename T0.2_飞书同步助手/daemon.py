# -*- coding: utf-8 -*-
"""
T0.2 飞书同步助手 - 桌面守护进程
手机飞书给自建机器人发消息 -> 追加到置顶窗口的 todos.json -> 回执"已加入待办 #N"
每天 digest_time 向最近会话推送未完成清单
"""
import json
import os
import sys
import threading
import time
import datetime

try:
    import lark_oapi as lark
    from lark_oapi.api.im.v1 import (
        P2ImMessageReceiveV1,
        ReplyMessageRequest,
        ReplyMessageRequestBody,
        CreateMessageRequest,
        CreateMessageRequestBody,
    )
except ImportError:
    print('缺少依赖，请先执行: python -m pip install lark-oapi')
    sys.exit(1)

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
CONFIG_FILE = os.path.join(BASE_DIR, 'config.json')
LOG_FILE = os.path.join(BASE_DIR, 'daemon.log')

_state = {'client': None, 'chat_id': None, 'seen': []}
_cfg = None


def log(msg):
    line = '%s  %s' % (datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S'), msg)
    try:
        if os.path.exists(LOG_FILE) and os.path.getsize(LOG_FILE) > 2 * 1024 * 1024:
            os.remove(LOG_FILE)
        with open(LOG_FILE, 'a', encoding='utf-8') as f:
            f.write(line + '\n')
    except Exception:
        pass
    print(line, flush=True)


def load_config():
    with open(CONFIG_FILE, 'r', encoding='utf-8-sig') as f:
        return json.load(f)


def save_config(cfg):
    with open(CONFIG_FILE, 'w', encoding='utf-8') as f:
        json.dump(cfg, f, ensure_ascii=False, indent=4)


def read_todos(path):
    with open(path, 'r', encoding='utf-8-sig') as f:
        return json.load(f)


def write_todos(path, data):
    """原子写入：先写临时文件再替换，避免置顶窗口读到半截文件"""
    tmp = path + '.t02tmp'
    with open(tmp, 'w', encoding='utf-8') as f:
        json.dump(data, f, ensure_ascii=False, indent=4)
    os.replace(tmp, path)


def append_todo(cfg, text):
    path = cfg.get('todos_path', '')
    data = read_todos(path)
    items = data.get('items', [])
    undone_before = len([i for i in items if not i.get('done')])
    items.append({'text': text, 'tag': cfg.get('tag', '远程'), 'done': False})
    data['items'] = items
    write_todos(path, data)
    return undone_before + 1


def _seen(mid):
    if mid in _state['seen']:
        return True
    _state['seen'].append(mid)
    if len(_state['seen']) > 500:
        del _state['seen'][:250]
    return False


def reply_text(message_id, text):
    try:
        req = (ReplyMessageRequest.builder()
               .message_id(message_id)
               .request_body(ReplyMessageRequestBody.builder()
                             .content(json.dumps({'text': text}, ensure_ascii=False))
                             .msg_type('text').build())
               .build())
        resp = _state['client'].im.v1.message.reply(req)
        if not resp.success():
            log('回执失败 code=%s msg=%s' % (resp.code, resp.msg))
    except Exception as e:
        log('回执异常: %s' % e)


def send_text(chat_id, text):
    try:
        req = (CreateMessageRequest.builder()
               .receive_id_type('chat_id')
               .request_body(CreateMessageRequestBody.builder()
                             .receive_id(chat_id)
                             .content(json.dumps({'text': text}, ensure_ascii=False))
                             .msg_type('text').build())
               .build())
        resp = _state['client'].im.v1.message.create(req)
        if not resp.success():
            log('推送失败 code=%s msg=%s' % (resp.code, resp.msg))
    except Exception as e:
        log('推送异常: %s' % e)


def on_message(data: P2ImMessageReceiveV1):
    try:
        event = data.event
        msg = event.message
        sender = getattr(event, 'sender', None)
        stype = getattr(sender, 'sender_type', None)
        if stype and stype != 'user':
            return
        mid = msg.message_id
        if _seen(mid):
            return
        chat = getattr(msg, 'chat_id', None)
        if chat:
            _state['chat_id'] = chat
            if _cfg and _cfg.get('chat_id') != chat:
                _cfg['chat_id'] = chat
                try:
                    save_config(_cfg)
                except Exception:
                    pass
        if msg.message_type != 'text':
            reply_text(mid, '目前只支持文字消息')
            return
        text = json.loads(msg.content).get('text', '').strip()
        if not text:
            return
        idx = append_todo(_cfg, text)
        reply_text(mid, '已加入待办 #%d：%s' % (idx, text[:30]))
        log('新增待办 #%d: %s' % (idx, text[:50]))
    except Exception as e:
        log('处理消息异常: %s' % e)


def digest_worker():
    last_date = None
    while True:
        try:
            now = datetime.datetime.now()
            hh, mm = [int(x) for x in _cfg.get('digest_time', '08:30').split(':')]
            if last_date != now.date() and (now.hour, now.minute) >= (hh, mm):
                last_date = now.date()
                chat = _state['chat_id'] or _cfg.get('chat_id')
                if chat:
                    data = read_todos(_cfg['todos_path'])
                    undone = [i.get('text', '') for i in data.get('items', []) if not i.get('done')]
                    if undone:
                        lines = ['今日待办共 %d 项：' % len(undone)]
                        lines += ['%d. %s' % (n + 1, t) for n, t in enumerate(undone[:20])]
                        if len(undone) > 20:
                            lines.append('... 其余 %d 项略' % (len(undone) - 20))
                        send_text(chat, '\n'.join(lines))
                        log('已发送每日清单（%d 项未完成）' % len(undone))
        except Exception as e:
            log('每日清单异常: %s' % e)
        time.sleep(30)


def main():
    global _cfg
    _cfg = load_config()
    app_id = _cfg.get('app_id', '').strip()
    app_secret = _cfg.get('app_secret', '').strip()
    if not app_id or not app_secret or 'xxx' in app_id or '粘贴' in app_secret:
        print('config.json 里的 app_id / app_secret 还没填，请按 说明.md 的步骤创建应用后填入。')
        sys.exit(2)
    _state['client'] = (lark.Client.builder()
                        .app_id(app_id)
                        .app_secret(app_secret)
                        .build())
    handler = (lark.EventDispatcherHandler.builder('', '')
               .register_p2_im_message_receive_v1(on_message)
               .build())
    threading.Thread(target=digest_worker, daemon=True).start()
    ws = lark.ws.Client(app_id, app_secret,
                        event_handler=handler,
                        log_level=lark.LogLevel.INFO)
    log('守护进程启动，正在建立长连接...')
    ws.start()


if __name__ == '__main__':
    main()
