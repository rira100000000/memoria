require "rails_helper"

RSpec.describe MemoriaServer::Routines do
  let(:character) { create(:character) }
  let(:routines) { [{ key: "morning", recurrence: "0 7 * * *", purpose: "朝の見回り", action: "share", remember: false }] }

  let(:plugin) do
    declared = -> { routines }
    Class.new(MemoriaServer::Plugin) {
      def name = :routine_test_xyz
      define_method(:enabled_for?) { |c| c.name != "無効" }
      define_method(:routines) { |_character| declared.call }
    }.new
  end

  before { MemoriaServer::Plugin.register(plugin) }
  after { MemoriaServer::Plugin.unregister(:routine_test_xyz) }

  def sync = described_class.sync!([character])

  it "creates a pending recurring wakeup for each declared routine and enqueues it" do
    travel_to Time.zone.parse("2026-10-21 15:00") do
      report = sync

      wakeup = character.scheduled_wakeups.find_by(routine_key: "routine_test_xyz:morning")
      expect(report[:created]).to eq([wakeup.id])
      expect(wakeup).to have_attributes(status: "pending", purpose: "朝の見回り", action: "share", remember: false, origin: "user",
        recurrence: "0 7 * * *", scheduled_at: Time.zone.parse("2026-10-22 07:00"))
      expect(ThinkingLoopJob).to have_been_enqueued.with(character.id, wakeup.id, wakeup.scheduled_at.to_i)
    end
  end

  it "does nothing when the declaration has not changed" do
    sync
    clear_enqueued_jobs

    expect(sync.values.flatten).to be_empty
    expect(ThinkingLoopJob).not_to have_been_enqueued
  end

  it "updates the purpose in place without rescheduling" do
    sync
    clear_enqueued_jobs
    routines.first[:purpose] = "朝の見回り（改）"

    report = sync

    expect(character.scheduled_wakeups.count).to eq(1)
    expect(character.scheduled_wakeups.first.purpose).to eq("朝の見回り（改）")
    expect(report[:updated].size).to eq(1)
    expect(ThinkingLoopJob).not_to have_been_enqueued
  end

  it "reschedules when the time changes" do
    travel_to Time.zone.parse("2026-10-21 15:00") do
      sync
      routines.first[:recurrence] = "0 18 * * *"

      report = sync

      expect(report[:rescheduled].size).to eq(1)
      expect(character.scheduled_wakeups.first.scheduled_at).to eq(Time.zone.parse("2026-10-21 18:00"))
    end
  end

  it "cancels a routine that is no longer declared" do
    sync
    routines.clear

    report = sync

    expect(report[:cancelled].size).to eq(1)
    expect(character.scheduled_wakeups.first.status).to eq("cancelled")
  end

  it "leaves other wakeups alone" do
    other = create(:scheduled_wakeup, character: character)
    routines.clear

    sync

    expect(other.reload.status).to eq("pending")
  end

  it "skips a routine without a valid recurrence" do
    routines.first[:recurrence] = "いつか"

    expect(sync[:created]).to be_empty
  end

  it "does not declare routines for a character the plugin is disabled for" do
    character.update!(name: "無効")

    expect(sync[:created]).to be_empty
  end
end
