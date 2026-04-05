class Character < ApplicationRecord
  belongs_to :user
  has_many :chat_session_records, dependent: :destroy
  has_many :channel_bindings, dependent: :destroy

  validates :name, presence: true

  scope :thinking_loop_active, -> { where(thinking_loop_enabled: true) }

  before_create :set_vault_dir_name

  def vault_path
    File.join(user.vault_path, vault_dir_name)
  end

  def enable_thinking_loop!
    update!(thinking_loop_enabled: true)
    ThinkingLoopWorker.perform_async(id)
  end

  def disable_thinking_loop!
    update!(thinking_loop_enabled: false)
    # スケジュール済みジョブをキャンセル
    require "sidekiq/api"
    Sidekiq::ScheduledSet.new.select { |job|
      job.klass == "ThinkingLoopWorker" && job.args == [id]
    }.each(&:delete)
  end

  private

  def set_vault_dir_name
    self.vault_dir_name ||= name.gsub(/[^\w\s-]/, "").gsub(/\s+/, "_").downcase.presence || "char_#{SecureRandom.hex(4)}"
  end
end
