class Character < ApplicationRecord
  belongs_to :user
  belongs_to :reading_companion, class_name: "Character", optional: true
  # 自分を reading_companion として指している他キャラ。削除時は nullify して
  # 相手の reading_companion_id を NULL に戻す (FK制約回避)
  has_many :companioned_by_characters,
           class_name: "Character",
           foreign_key: :reading_companion_id,
           dependent: :nullify,
           inverse_of: :reading_companion
  has_many :chat_session_records, dependent: :destroy
  has_many :channel_bindings, dependent: :destroy
  has_many :scheduled_wakeups, dependent: :destroy
  has_many :reading_progresses, dependent: :destroy
  has_many :chat_results, dependent: :destroy
  has_many :api_usage_logs, dependent: :nullify

  validates :name, presence: true

  scope :thinking_loop_active, -> { where(thinking_loop_enabled: true) }

  before_create :set_vault_dir_name

  def vault_path
    File.join(user.vault_path, vault_dir_name)
  end

  # --- ペット ---

  def has_pet?
    pet_config.present? && pet_config["name"].present?
  end

  def pet_name
    pet_config&.dig("name")
  end

  def pet_appearance
    pet_config&.dig("appearance")
  end

  def pet_traits
    pet_config&.dig("traits")
  end

  def adopt_pet!(name:, appearance:)
    traits = Companion::AdoptPetTool::APPEARANCES[appearance]
    update!(pet_config: {
      "name" => name,
      "appearance" => appearance,
      "traits" => traits,
      "adopted_at" => Time.current.strftime("%Y-%m-%d %H:%M"),
    })
  end

  # --- 読書 ---

  def current_reading
    reading_progresses.find_by(status: "reading")
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
    self.vault_dir_name ||= name.gsub(/[^\w\s-]/, "").gsub(/\s+/, "_").downcase.presence || "char_#{SecureRandom.hex(4)}"
  end
end
