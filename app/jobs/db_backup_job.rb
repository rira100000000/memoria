require "fileutils"
require "sqlite3"

# 全 SQLite ファイルのスナップショットを取るジョブ
#
# - SQLite の VACUUM INTO を使うので動作中の DB でも一貫したコピーが作れる
# - storage/*.sqlite3 を全部対象にするので primary だけでなく cache/queue/cable も対象
# - storage/backups/YYYYMMDD_HHMMSS/ にダンプ
# - KEEP 件より古いスナップショットは自動削除
#
# 手動実行: bin/rails db:backup
# 定期実行: config/recurring.yml で毎日 4 時にスケジュール
class DbBackupJob < ApplicationJob
  queue_as :low

  KEEP = 7
  STORAGE_ROOT = Rails.root.join("storage").freeze

  def perform
    sources = Dir[STORAGE_ROOT.join("*.sqlite3").to_s]
    if sources.empty?
      Rails.logger.info("[DbBackupJob] No SQLite files found in #{STORAGE_ROOT}, nothing to back up")
      return
    end

    timestamp = Time.current.strftime("%Y%m%d_%H%M%S")
    backup_dir = STORAGE_ROOT.join("backups", timestamp)
    FileUtils.mkdir_p(backup_dir)

    sources.each do |source|
      target = backup_dir.join(File.basename(source)).to_s
      snapshot(source, target)
      Rails.logger.info("[DbBackupJob] #{File.basename(source)} -> #{target}")
    end

    prune_old_backups
  end

  private

  def snapshot(source, target)
    db = SQLite3::Database.new(source)
    db.execute("VACUUM INTO ?", [target])
  ensure
    db&.close
  end

  def prune_old_backups
    all_dirs = Dir[STORAGE_ROOT.join("backups", "*").to_s].sort
    return if all_dirs.size <= KEEP

    all_dirs[0...-KEEP].each do |dir|
      FileUtils.rm_rf(dir)
      Rails.logger.info("[DbBackupJob] pruned old snapshot #{File.basename(dir)}")
    end
  end
end
