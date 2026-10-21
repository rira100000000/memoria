require "rails_helper"

# memoria 本体（接続と表出）が、同梱の見本アダプタ（memoria_core）や、プラグインにすべき能力の
# 実装を直接参照していないかを確かめる。線引きと移行計画は README の「責務」を参照。
#
# known は移行前から残っている参照。移行が進むたびに減らす。新しい参照を足すと落ちる。
# 本体に何か足したいときは、まず「どのキャラ・どの記憶システムでも要る、接続と表出の仕組みか」を考える。
RSpec.describe "memoria 本体の境界" do
  let(:root) { Rails.root }

  let(:ms_files) do
    %w[
      lib/memoria_server.rb
      lib/memoria_server/adapter.rb
      lib/memoria_server/adapters/http.rb
      lib/memoria_server/presence_manager.rb
      lib/memoria_server/push.rb
      lib/memoria_server/redis_client.rb
      lib/memoria_server/capability.rb
      lib/memoria_server/capabilities/*.rb
      lib/memoria_server/streaming_metadata_extractor.rb
      lib/memoria_server/context_builder.rb
      lib/memoria_server/audio.rb
      lib/memoria_server/audio/*.rb
      lib/memoria_server/plugin.rb
      lib/memoria_server/routines.rb
      bin/jobs
      app/controllers/application_controller.rb
      app/controllers/api/v1/*.rb
      app/models/{application_record,device,device_key,presence,transfer,channel_binding,user,admin_key,character,scheduled_wakeup}.rb
      app/services/message_dispatcher.rb
      app/jobs/{application_job,thinking_loop_job,conversation_timeout_job,db_backup_job}.rb
      bin/discord_bot.rb
      config/initializers/memoria_server.rb
    ]
  end

  # memoria_core（記憶・プロンプト・LLM）と、プラグインにすべき能力（思考・読書・ペット）の定数。
  # 既定のアダプタを選ぶための Adapters::MemoriaCore は対象外
  let(:forbidden) do
    /(?<!Adapters::)\b(MemoriaCore|ChatSession|ChatSessionRecord|ChatResult|PromptBuilder|ProspectiveMemory|
      ReflectionService|LlmClient|ApiBudget|ApiUsageLog|ClaudeCli|McpServer|Thinking|Reading|ReadingProgress|Companion|
      SleepPhaseJob|TagProfilingJob|SummarizeJob|ChatJob)\b/x
  end

  let(:known) do
    {
      "app/jobs/conversation_timeout_job.rb" => %w[ChatSession ChatSessionRecord SleepPhaseJob TagProfilingJob],
      "app/models/character.rb" => %w[Companion],
      "app/models/user.rb" => %w[MemoriaCore],
      "bin/discord_bot.rb" => %w[ChatSession],
    }
  end

  def references
    files = ms_files.flat_map { |pattern| Dir.glob(root.join(pattern).to_s) }
    files.each_with_object({}) do |path, refs|
      found = File.readlines(path, encoding: "utf-8")
        .reject { |line| line.strip.start_with?("#") }
        .flat_map { |line| line.scan(forbidden).flatten }
        .uniq.sort
      refs[Pathname.new(path).relative_path_from(root).to_s] = found if found.any?
    end
  end

  it "does not add new references to memoria_core or to abilities" do
    added = references.to_h { |file, consts| [file, consts - known.fetch(file, [])] }.reject { |_, c| c.empty? }

    expect(added).to be_empty, "memoria 本体から新しく参照している: #{added}"
  end

  it "lists only references that still exist, so that the list shrinks as the migration goes" do
    refs = references
    stale = known.to_h { |file, consts| [file, consts - refs.fetch(file, [])] }.reject { |_, c| c.empty? }

    expect(stale).to be_empty, "もう参照していないので known から消す: #{stale}"
  end
end
