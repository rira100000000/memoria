class AddReadingCompanionToCharacters < ActiveRecord::Migration[8.1]
  def change
    add_reference :characters, :reading_companion, foreign_key: { to_table: :characters }, null: true
  end
end
