require "rails_helper"

# memoria 本体（接続と表出）が、同梱の見本アダプタ（memoria_core）の実装を直接参照していないかを確かめる。
# 線引きは README の「責務」を参照。memoria_core を使うのは、アダプタ（lib/memoria_server/adapters/ の
# memoria_core 系）を通すときだけ。本体に何か足したいときは、まず「どのキャラ・どの記憶システムでも要る、
# 接続と表出の仕組みか」を考える。違えば memoria_core（app/memoria_core/）かプラグインに置く。
RSpec.describe "memoria 本体の境界" do
  let(:root) { Rails.root }
  let(:core_dirs) { %w[services models jobs].map { |dir| root.join("app/memoria_core", dir) } }

  # 本体のファイル: memoria_core とそのアダプタ以外のすべて
  let(:server_files) do
    files = Dir.glob(root.join("{app,lib/memoria_server,config}/**/*.rb").to_s) +
      [root.join("lib/memoria_server.rb"), root.join("bin/discord_bot.rb"), root.join("bin/jobs"), root.join("db/seeds.rb")].map(&:to_s)
    files.reject { |path|
      path.start_with?(root.join("app/memoria_core").to_s) || path.match?(%r{lib/memoria_server/adapters/.*memoria_core\.rb\z})
    }
  end

  # memoria_core の定数: app/memoria_core/ の各ファイルが定義する一番外側の名前と、記憶の本体（MemoriaCore）。
  # コントローラは Api 名前空間を本体と共有しているので、ファイル名から作るクラス名で見る
  let(:core_constants) do
    names = core_dirs.flat_map { |dir|
      Dir.glob("#{dir}/**/*.rb").map { |path| Pathname.new(path).relative_path_from(dir).each_filename.first.delete_suffix(".rb").camelize }
    }
    names += Dir.glob(root.join("app/memoria_core/controllers/**/*_controller.rb").to_s).map { |path| File.basename(path, ".rb").camelize }
    (names + ["MemoriaCore"]).uniq
  end

  it "does not reference memoria_core except through its adapter" do
    pattern = /(?<!Adapters::)\b(#{core_constants.join("|")})\b/
    refs = server_files.each_with_object({}) do |path, found|
      consts = File.readlines(path, encoding: "utf-8")
        .reject { |line| line.strip.start_with?("#") }
        .flat_map { |line| line.scan(pattern).flatten }
        .uniq
      found[Pathname.new(path).relative_path_from(root).to_s] = consts if consts.any?
    end

    expect(refs).to be_empty, "memoria 本体から memoria_core を参照している: #{refs}"
  end

  it "knows memoria_core's constants" do
    expect(core_constants).to include("ChatSession", "Thinking", "ClaudeCli", "SleepPhaseJob", "ApiUsageLog", "ChatsController", "MemoriaCore")
  end

  it "does not hard-code how a character calls the user" do
    # 呼び方はキャラの設定（system_prompt）が決める。プロンプトや説明では「ユーザー」と書く
    files = Dir.glob(root.join("{app,lib,bin,config}/**/*.rb").to_s) + Dir.glob(root.join("bin/*").to_s)
    hits = files.select { |path| File.file?(path) && File.read(path, encoding: "utf-8").include?("マスター") }

    expect(hits.map { |path| Pathname.new(path).relative_path_from(root).to_s }).to be_empty
  end
end
