class AddThinkingLoopToCharacters < ActiveRecord::Migration[8.1]
  def change
    unless column_exists?(:characters, :thinking_loop_enabled)
      add_column :characters, :thinking_loop_enabled, :boolean, default: false, null: false
    end
    unless column_exists?(:characters, :thinking_loop_interval_minutes)
      add_column :characters, :thinking_loop_interval_minutes, :integer, default: 60, null: false
    end

    change_column_default :characters, :thinking_loop_enabled, false
    change_column_null :characters, :thinking_loop_enabled, false, false
    change_column_default :characters, :thinking_loop_interval_minutes, 60
    change_column_null :characters, :thinking_loop_interval_minutes, false, 60
  end
end
