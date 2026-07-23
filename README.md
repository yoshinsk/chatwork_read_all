# Chatwork Read All

Chatworkの未読チャットを、任意のタイミングで起動して一括既読にする小さなWindowsアプリです。

自分以外のユーザーが多数のグループチャットに同じ案内を送信した場合など、読む必要のない大量未読をまとめて処理する目的で使います。

## 最新版ダウンロード

[最新版ZIPをダウンロード](https://github.com/yoshinsk/chatwork_read_all/archive/refs/heads/main.zip)

ZIPを展開して、展開先フォルダ内の `ChatworkReadAll.cmd` を実行してください。実行した時だけ確認ダイアログが表示されます。

## 動作環境

- Windows 10
- Windows 11
- Windows PowerShell 5.1
- インターネット接続
- Chatwork APIキー

追加の.NET SDK、Python、Node.jsは不要です。

## できること

- Chatwork APIキーを現在のWindowsユーザー用に暗号化して保存します。
- `ChatworkReadAll.cmd` を実行した時に「すべて既読にしますか？」と確認します。
- `はい` を選ぶと、未読があるチャットを最新メッセージまで既読にします。
- `いいえ` を選ぶと、何も変更せず終了します。
- 実行前の確認画面で、未読ルーム数、未読メッセージ数、自分宛て未読数を表示します。

## 初期設定

1. ZIPを展開します。
2. 展開したフォルダで `Settings.cmd` を実行します。
3. Chatwork APIキーを入力して保存します。
4. 保存時にChatwork APIへ接続し、キーが有効か確認します。

APIキーは `%APPDATA%\ChatworkReadAll\config.json` に保存されます。保存値はWindows DPAPIで現在のWindowsユーザー向けに暗号化され、平文では保存されません。

## 実行方法

```cmd
ChatworkReadAll.cmd
```

このアプリはWindows起動時には自動実行しません。既読化したいタイミングで `ChatworkReadAll.cmd` を実行してください。

設定画面を再度開く場合:

```cmd
Settings.cmd
```

## 配布ファイル

- `ChatworkReadAll.cmd`: 通常実行用です。確認ダイアログを表示し、`はい` の場合だけ一括既読化します。
- `Settings.cmd`: APIキー設定用です。既読化は行わず、APIキーの保存・差し替えだけを行います。
- `ChatworkReadAll.ps1`: アプリ本体です。APIキー保存、Chatwork API通信、確認画面、既読化処理を実装しています。
- `README.md`: 利用者向けの説明書です。

## Chatwork APIキーの取得場所

Chatwork画面右上の利用者名メニューから、サービス連携のAPIトークン画面を開いて取得します。組織設定によっては、組織管理者へのAPI利用申請が必要です。

公式ドキュメント: [Chatwork API ご利用開始方法](https://developer.chatwork.com/docs/getting-started)

## 既読化の仕組み

Chatwork APIには、全チャットを一度に既読にする専用エンドポイントはありません。そのため、このアプリは次の順で処理します。

1. `GET /my/status` で現在の未読数を確認します。
2. `GET /rooms` で参加チャット一覧を取得します。
3. `unread_num > 0` のチャットだけ `GET /rooms/{room_id}/messages?force=1` で最新メッセージを取得します。
4. `PUT /rooms/{room_id}/messages/read` に `message_id` をフォームボディで送り、そのIDまで既読化します。

公式ドキュメント:

- [自分の状態を取得する](https://developer.chatwork.com/reference/get-my-status)
- [チャット一覧を取得する](https://developer.chatwork.com/reference/get-rooms)
- [チャットのメッセージ一覧を取得する](https://developer.chatwork.com/reference/get-rooms-room_id-messages)
- [チャットのメッセージを既読にする](https://developer.chatwork.com/reference/put-rooms-room_id-messages-read)

2025年7月3日以降、Chatwork APIのPOST/PUT系パラメーターはクエリではなく `application/x-www-form-urlencoded` のボディで送る必要があります。このアプリもその形式で送信します。

関連告知: [2025/04/03 APIリクエストの仕様変更についてのお知らせ](https://developer.chatwork.com/changelog/202501-notice)

## 注意点

- 既読化は、自分のアカウントの未読状態だけを変更します。他ユーザーの既読状態は変更できません。
- 自分宛て未読や重要な未読も既読になります。
- Windows起動時の自動実行や常駐は行いません。
- APIキーは第三者に渡さないでください。Chatwork公式ドキュメントでも、APIキーをHTTPヘッダーで送信し、第三者へ開示しないよう案内されています。
- Chatwork APIの利用回数制限に達した場合、APIが返すリセット時刻に従って待機します。
- 403が返る場合、APIトークンのスコープまたは対象チャットへの権限が不足しています。
