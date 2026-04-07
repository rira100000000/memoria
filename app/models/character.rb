class Character < ApplicationRecord
  belongs_to :user
  belongs_to :reading_companion, class_name: "Character", optional: true
  has_many :chat_session_records, dependent: :destroy
  has_many :channel_bindings, dependent: :destroy
  has_many :scheduled_wakeups, dependent: :destroy
  has_many :reading_progresses, dependent: :destroy

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
