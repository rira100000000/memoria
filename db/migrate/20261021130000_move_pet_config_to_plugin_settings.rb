class MovePetConfigToPluginSettings < ActiveRecord::Migration[8.1]
  # プラグインがキャラクターごとに持つ設定（プラグインの name をキーにした Hash）。
  # ペットはプラグインに移ったので、専用の列から "pet" の設定へ移す
  def up
    add_column :characters, :plugin_settings, :json, null: false, default: {}
    execute(<<~SQL)
      UPDATE characters SET plugin_settings = json_object('pet', json(pet_config))
      WHERE pet_config IS NOT NULL AND pet_config != 'null'
    SQL
    remove_column :characters, :pet_config
  end

  def down
    add_column :characters, :pet_config, :json
    execute(<<~SQL)
      UPDATE characters SET pet_config = json_extract(plugin_settings, '$.pet')
      WHERE json_extract(plugin_settings, '$.pet') IS NOT NULL
    SQL
    remove_column :characters, :plugin_settings
  end
end
