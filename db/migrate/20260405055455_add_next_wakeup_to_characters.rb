class AddNextWakeupToCharacters < ActiveRecord::Migration[8.1]
  def change
    add_column :characters, :next_wakeup_at, :datetime
    add_column :characters, :next_wakeup_job_id, :string
  end
end
