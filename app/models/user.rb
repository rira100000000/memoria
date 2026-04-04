class User < ApplicationRecord
  has_many :characters, dependent: :destroy
  has_secure_token :api_token

  validates :email, presence: true, uniqueness: true

  def vault_path
    File.join(MemoriaCore.vault_root, id.to_s)
  end
end
