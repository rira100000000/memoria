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

  def append_message(role, content)
    self.messages ||= []
    self.messages << { "role" => role, "content" => content }
    self.last_message_at = Time.current
    save!
  end

  def message_count
    (messages || []).length
  end
end
