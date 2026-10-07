class ScheduledWakeup < ApplicationRecord
  # proposed: キャラが自分で入れた繰り返しの予定。マスターが承認するまで動かない
  STATUSES = %w[pending proposed executed cancelled].freeze
  ORIGINS = %w[user self].freeze
  TIME_ZONE = "Asia/Tokyo"
  # 繰り返しの最短間隔（毎分起きるような予定で予算を使い切らないため）
  MIN_RECURRING_INTERVAL = 1.hour
  # 繰り返しの予定がこれ以上遅れたら、その回は飛ばす（サーバ停止明けに古い回を実行しない）
  MAX_RECURRING_LATENESS = 3.hours

  belongs_to :character

  validates :scheduled_at, presence: true
  validates :purpose, presence: true
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :origin, inclusion: { in: ORIGINS }
  validate :recurrence_must_be_parseable

  scope :pending, -> { where(status: "pending") }
  scope :proposed, -> { where(status: "proposed") }
  scope :upcoming, -> { pending.where("scheduled_at > ?", Time.current).order(:scheduled_at) }
  scope :due, -> { pending.where("scheduled_at <= ?", Time.current) }
  scope :recurring, -> { where.not(recurrence: nil) }
  scope :one_shot, -> { where(recurrence: nil) }

  # cron式か英語の自然文（"every day at 7:00"）を解釈し、タイムゾーン付きのcronにする
  # @return [Fugit::Cron, nil]
  def self.parse_recurrence(text)
    cron = Fugit.parse_cronish(text.to_s.strip)
    return nil unless cron
    return cron if cron.timezone

    Fugit::Cron.parse("#{cron.original} #{TIME_ZONE}")
  end

  def recurring?
    recurrence.present?
  end

  def cron
    return nil unless recurring?

    self.class.parse_recurrence(recurrence)
  end

  def next_occurrence_after(time)
    cron.next_time(time).to_t.in_time_zone
  end

  # この回を飛ばしてよいほど遅れているか（繰り返しの予定のみ）
  def stale?(now = Time.current)
    return false unless recurring?

    now - scheduled_at > [cron.rough_frequency / 2, MAX_RECURRING_LATENESS].min
  end

  # 失敗・スキップを必ず知らせるべき予定か
  # マスターに頼まれた予定と「伝える」予定は、黙って消えてはいけない
  def notify_on_failure?
    origin == "user" || action == "share"
  end

  def execute!
    update!(status: "executed")
  end

  # 繰り返しの予定を次の回へ進め、ジョブを積み直す
  # 遅れて起きた場合は、取りこぼした回をまとめて飛ばして現在時刻より後の回にする
  def advance!(from: Time.current)
    update!(scheduled_at: next_occurrence_after([from, scheduled_at].max))
    enqueue!
  end

  def approve!(now: Time.current)
    update!(status: "pending", scheduled_at: next_occurrence_after(now))
    enqueue!
  end

  def cancel!
    update!(status: "cancelled")
    # スケジュール済みジョブのキャンセルは不要：
    # ThinkingLoopJob 側で wakeup.status をチェックして早期 return する
  end

  # 予定時刻を引数に含めて積む。予定が繰り越された後に古いジョブが動いても、
  # 時刻の不一致で ThinkingLoopJob 側が早期 return する
  def enqueue!
    ThinkingLoopJob.set(wait_until: scheduled_at).perform_later(character_id, id, scheduled_at.to_i)
  end

  def summary_line(with_id: false)
    line = +"#{scheduled_at.in_time_zone(TIME_ZONE).strftime('%m/%d %H:%M')} — #{purpose}"
    line << " [#{action}]" if action.present?
    notes = []
    notes << "繰り返し: #{recurrence}" if recurring?
    notes << "承認待ちの提案" if status == "proposed"
    line << "（#{notes.join(' / ')}）" if notes.any?
    line << " (ID:#{id})" if with_id
    line
  end

  private

  def recurrence_must_be_parseable
    return unless recurring?

    errors.add(:recurrence, "を解釈できません") unless self.class.parse_recurrence(recurrence)
  end
end
