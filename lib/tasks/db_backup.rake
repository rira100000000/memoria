namespace :db do
  desc "Snapshot all SQLite files in storage/ to storage/backups/YYYYMMDD_HHMMSS/"
  task backup: :environment do
    DbBackupJob.perform_now
    puts "[db:backup] done"
  end
end
