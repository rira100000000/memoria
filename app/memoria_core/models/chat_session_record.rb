# chat_sessionsテーブルのActiveRecordモデル
# サービス層のChatSessionがこれを通じてDB永続化を行う
class ChatSessionRecord < ApplicationRecord
  self.table_name = "chat_sessions"

  belongs_to :character
  belongs_to :user

  validates :status, presence: true, inclusion: { in: %w[active closed] }

  scope :active, -> { where(status: "active") }

  def active?
    status == "active"
  end

  def close!
    update!(status: "closed")
  end

  # @param work [Array<String>, nil] この返答を書くまでにした作業の記録（"[Bash] ..." など）。
  #   claude -p は1回ごとに独立して動くので、次の返答のプロンプトに入れて、同じ下調べを繰り返さないようにする
  def append_message(role, content, work: nil)
    self.messages ||= []
    message = { "role" => role, "content" => content }
    message["work"] = work if work.present?
    self.messages << message
    self.last_message_at = Time.current
    save!
  end

  def message_count
    (messages || []).length
  end
end
