# プラットフォーム別メッセージ送信ディスパッチャー
# Phase 3: pending_messagesに保存（APIポーリングで取得）
# Phase 4: Discord/LINE送信アダプターを追加予定
class MessageDispatcher
  def initialize(character)
    @character = character
    @user = character.user
  end

  # 自発的メッセージを配信
  # @param content [String] メッセージ内容
  # @param trigger_type [String] "thinking_loop" or "sleep_phase"
  # @param topic_tag [String, nil] 関連トピックタグ
  def dispatch(content, trigger_type:, topic_tag: nil)
    # pending_messagesに保存（全チャネル共通）
    message = PendingMessage.create!(
      character: @character,
      user: @user,
      trigger_type: trigger_type,
      content: content,
      topic_tag: topic_tag
    )

    # Phase 4: ChannelBinding経由でDiscord/LINEにも送信
    # deliver_to_channels(message)

    message
  end
end
