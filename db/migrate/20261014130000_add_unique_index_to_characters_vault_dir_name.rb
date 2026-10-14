class AddUniqueIndexToCharactersVaultDirName < ActiveRecord::Migration[8.1]
  def change
    # vault_dir_name は記憶の置き場所を決めるので、同じユーザーの中で重ならないようにする
    add_index :characters, [:user_id, :vault_dir_name], unique: true
  end
end
