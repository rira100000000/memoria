require "rails_helper"

RSpec.describe MemoriaServer::Plugins::ScheduleTime do
  # 日本時間 2026-10-26（月）00:06
  let(:now) { Time.zone.parse("2026-10-26 00:06") }

  def parse(text)
    described_class.parse(text, now: now)
  end

  def jst(text)
    Time.zone.parse(text)
  end

  it "reads times in Japan time" do
    expect(parse("明日 14:23").time_zone.name).to eq("Asia/Tokyo")
  end

  describe "relative" do
    it "reads minutes and hours from now" do
      expect(parse("30分後")).to eq(now + 30.minutes)
      expect(parse("3時間後")).to eq(now + 3.hours)
      expect(parse("1時間30分後")).to eq(now + 90.minutes)
    end

    it "reads days from now" do
      expect(parse("3日後")).to eq(now + 3.days)
    end

    it "reads a time of day some days later" do
      expect(parse("3日後の12時ごろ")).to eq(jst("2026-10-29 12:00"))
      expect(parse("2日後 9:30")).to eq(jst("2026-10-28 09:30"))
      expect(parse("1日後の夜")).to eq(jst("2026-10-27 21:00"))
    end
  end

  describe "day words" do
    it "reads tomorrow with a clock time" do
      expect(parse("明日 14:23")).to eq(jst("2026-10-27 14:23"))
      expect(parse("明日の14時")).to eq(jst("2026-10-27 14:00"))
      expect(parse("明日の朝8時")).to eq(jst("2026-10-27 08:00"))
      expect(parse("明日の夜8時")).to eq(jst("2026-10-27 20:00"))
    end

    it "reads parts of the day" do
      expect(parse("明日の朝")).to eq(jst("2026-10-27 07:00"))
      expect(parse("明日の昼")).to eq(jst("2026-10-27 12:00"))
    end

    it "reads the day after tomorrow" do
      expect(parse("明後日の15時半")).to eq(jst("2026-10-28 15:30"))
      expect(parse("あさって 午後3時")).to eq(jst("2026-10-28 15:00"))
    end

    it "keeps today as today, even when the time has passed" do
      expect(parse("今日 21:00")).to eq(jst("2026-10-26 21:00"))
      expect(parse("今日 0:01")).to eq(jst("2026-10-26 00:01"))
    end

    it "asks for a time when only the day is given" do
      expect { parse("明日") }.to raise_error(described_class::Error, /時刻/)
    end
  end

  describe "absolute" do
    it "reads dates with a year" do
      expect(parse("2026-10-29 12:00")).to eq(jst("2026-10-29 12:00"))
      expect(parse("2026/10/29 12:00")).to eq(jst("2026-10-29 12:00"))
      expect(parse("2026年10月29日 12時")).to eq(jst("2026-10-29 12:00"))
    end

    it "reads ISO 8601" do
      expect(parse("2026-10-29T12:00:00+09:00")).to eq(jst("2026-10-29 12:00"))
      expect(parse("2026-10-29T03:00:00Z")).to eq(jst("2026-10-29 12:00"))
      expect(parse("2026-10-29T12:00")).to eq(jst("2026-10-29 12:00"))
    end

    it "reads dates without a year as the nearest one" do
      expect(parse("10/29 12:00")).to eq(jst("2026-10-29 12:00"))
      expect(parse("10月29日 午後1時")).to eq(jst("2026-10-29 13:00"))
      expect(parse("10/25 12:00")).to eq(jst("2026-10-25 12:00"))

      december = Time.zone.parse("2026-12-30 10:00")
      expect(described_class.parse("1/3 9:00", now: december)).to eq(jst("2027-01-03 09:00"))
    end

    it "reads full-width digits" do
      expect(parse("１０月２９日 １２：００")).to eq(jst("2026-10-29 12:00"))
    end

    it "asks for a time when only the date is given" do
      expect { parse("10/29") }.to raise_error(described_class::Error, /時刻/)
    end

    it "rejects dates that do not exist" do
      expect { parse("2/30 12:00") }.to raise_error(described_class::Error, /日付/)
    end
  end

  describe "clock time only" do
    it "takes the next time it comes" do
      expect(parse("21:00")).to eq(jst("2026-10-26 21:00"))
      expect(parse("0:01")).to eq(jst("2026-10-27 00:01"))
      expect(parse("9時")).to eq(jst("2026-10-26 09:00"))
      expect(parse("午後3時")).to eq(jst("2026-10-26 15:00"))
      expect(parse("深夜2時")).to eq(jst("2026-10-26 02:00"))
    end

    it "rejects impossible times" do
      expect { parse("25:00") }.to raise_error(described_class::Error)
    end
  end

  it "returns nil for text it cannot read" do
    expect(parse("いつか")).to be_nil
    expect(parse("")).to be_nil
  end
end
