class AddDestinations < ActiveRecord::Migration[8.1]
  # キャラクターが自分から送るメッセージを、種類ごとのチャンネルに振り分ける
  def change
    add_column :channel_bindings, :purposes, :json, default: [], null: false
    add_column :scheduled_wakeups, :destination, :string
  end
end
