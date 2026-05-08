class Device < ApplicationRecord
  has_many :device_keys, dependent: :destroy
  has_many :active_presences, class_name: "Presence", foreign_key: :active_device_id, dependent: :nullify
  # Transfer ログ：from_device は nullify（移動元が消えても履歴は残せる）、
  # to_device は NOT NULL なのでデバイス削除時に該当ログも一緒に消す
  has_many :outgoing_transfers, class_name: "Transfer", foreign_key: :from_device_id, dependent: :nullify
  has_many :incoming_transfers, class_name: "Transfer", foreign_key: :to_device_id, dependent: :destroy

  validates :name, presence: true
  validates :slug, presence: true, uniqueness: true, format: { with: /\A[a-z0-9][a-z0-9\-_]*\z/ }

  def heartbeat!
    update_column(:last_heartbeat_at, Time.current)
  end
end
