class Character < ApplicationRecord
  belongs_to :user
  has_many :chat_session_records, dependent: :destroy
  has_many :channel_bindings, dependent: :destroy
  has_many :scheduled_wakeups, dependent: :destroy
  has_many :chat_results, dependent: :destroy
  has_many :api_usage_logs, dependent: :nullify

  # MemoriaServer
  has_one :presence, dependent: :destroy
  has_many :transfers, dependent: :destroy

  validates :name, presence: true
  # 記憶の置き場所（vault_path）を決める値。同じユーザーの中で重なると記憶を共有してしまう
  validates :vault_dir_name, presence: true, uniqueness: { scope: :user_id }

  scope :thinking_loop_active, -> { where(thinking_loop_enabled: true) }

  before_validation :set_vault_dir_name, on: :create

  def vault_path
    File.join(user.vault_path, vault_dir_name)
  end

  # --- 思考ループ ---

  def enable_thinking_loop!
    update!(thinking_loop_enabled: true)
    ThinkingLoopJob.perform_later(id)
  end

  def disable_thinking_loop!
    update!(thinking_loop_enabled: false)
    # スケジュール済みジョブのキャンセルは不要：
    # ThinkingLoopJob 側で thinking_loop_enabled? をチェックして早期 return する
  end

  private

  def set_vault_dir_name
    return if vault_dir_name.present? || name.blank?

    base = name.gsub(/[^\w\s-]/, "").gsub(/\s+/, "_").downcase.presence || "char_#{SecureRandom.hex(4)}"
    base = "#{base}_#{SecureRandom.hex(4)}" if user && user.characters.exists?(vault_dir_name: base)
    self.vault_dir_name = base
  end
end
