class Character < ApplicationRecord
  belongs_to :user
  has_many :pending_messages, dependent: :destroy

  validates :name, presence: true

  scope :thinking_loop_active, -> { where(thinking_loop_enabled: true) }

  before_create :set_vault_dir_name

  def vault_path
    File.join(user.vault_path, vault_dir_name)
  end

  private

  def set_vault_dir_name
    self.vault_dir_name ||= name.gsub(/[^\w\s-]/, "").gsub(/\s+/, "_").downcase.presence || "char_#{SecureRandom.hex(4)}"
  end
end
