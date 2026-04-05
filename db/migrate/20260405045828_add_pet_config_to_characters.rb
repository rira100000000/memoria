class AddPetConfigToCharacters < ActiveRecord::Migration[8.1]
  def change
    add_column :characters, :pet_config, :jsonb
  end
end
