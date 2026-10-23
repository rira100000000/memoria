require "rails_helper"

RSpec.describe ClaudeCli::LongThink do
  let(:dir) { Dir.mktmpdir("long_think_spec") }
  let(:path) { File.join(dir, "long_think.json") }
  let(:long_think) { ClaudeCli::LongThink.new(path) }
  let(:now) { Time.zone.local(2026, 1, 2, 3, 4, 5) }

  after { FileUtils.rm_rf(dir) }

  describe "#declare and #read" do
    it "writes the declaration and reads it back" do
      result = long_think.declare(30, "  ベンチマーク  ", now: now)

      expect(result).to include(minutes: 30, until: (now + 30.minutes).iso8601, capped: false)
      expect(result[:message]).to include("03:34", "30分")
      declaration = long_think.read
      expect(declaration.until_time.to_i).to eq((now + 30.minutes).to_i)
      expect(declaration.minutes).to eq(30)
      expect(declaration.reason).to eq("ベンチマーク")
      expect(Dir.children(dir)).to eq(["long_think.json"])
    end

    it "accepts minutes given as a string, rounding fractions up" do
      expect(long_think.declare("15", "学習", now: now)[:minutes]).to eq(15)
      expect(long_think.declare("2.5", "学習", now: now)[:minutes]).to eq(3)
      expect(long_think.read.minutes).to eq(3)
    end

    it "rounds fractional numbers up, as the tool description says" do
      expect(long_think.declare(2.5, "学習", now: now)[:minutes]).to eq(3)
      expect(long_think.declare(0.1, "学習", now: now)[:minutes]).to eq(1)
      expect(long_think.declare(59.5, "学習", now: now)).to include(minutes: 60, capped: false)
      expect(long_think.declare(60.5, "学習", now: now)).to include(minutes: 60, capped: true)
    end

    it "replaces an earlier declaration" do
      long_think.declare(10, "一つめ", now: now)
      long_think.declare(20, "二つめ", now: now)

      expect(long_think.read).to have_attributes(minutes: 20, reason: "二つめ")
    end

    it "caps minutes at #{described_class::MAX_MINUTES} and says so" do
      result = long_think.declare(90, "長い学習", now: now)

      expect(result).to include(minutes: 60, until: (now + 60.minutes).iso8601, capped: true)
      expect(result[:message]).to include("60分を超える指定だったので、60分にしました")
      expect(long_think.read.minutes).to eq(60)
    end

    it "does not mention the cap at exactly #{described_class::MAX_MINUTES} minutes" do
      result = long_think.declare(60, "ちょうど", now: now)

      expect(result).to include(minutes: 60, capped: false)
      expect(result[:message]).not_to include("超える")
    end

    [0, -5, "0", "abc", "", nil, "1e400"].each do |minutes|
      it "returns an error and writes nothing for minutes #{minutes.inspect}" do
        result = long_think.declare(minutes, "なにか", now: now)

        expect(result).to eq(error: "minutes には1以上の数を指定してください")
        expect(File.exist?(path)).to be(false)
        expect(long_think.read).to be_nil
      end
    end

    it "reads nil when there is no declaration or the file is broken" do
      expect(long_think.read).to be_nil

      File.write(path, "{not json")
      expect(long_think.read).to be_nil
    end
  end

  describe ClaudeCli::LongThink::Provider do
    let(:inner) do
      Class.new do
        attr_reader :calls

        def initialize
          @calls = []
        end

        def tools
          [{ name: "echo", description: "echo", parameters: { type: "OBJECT", properties: {} } }]
        end

        def call(name, args)
          @calls << [name, args]
          { echoed: args["text"] }
        end
      end.new
    end
    let(:provider) { described_class.new(inner, long_think) }

    it "adds long_think after the original tools" do
      expect(provider.tools.map { |t| t[:name] }).to eq(%w[echo long_think])
      expect(provider.tools.last).to eq(ClaudeCli::LongThink::DEFINITION)
    end

    it "handles long_think itself without calling the original provider" do
      result = provider.call("long_think", { "minutes" => 5, "reason" => "計測" })

      expect(result).to include(minutes: 5, capped: false)
      expect(long_think.read).to have_attributes(minutes: 5, reason: "計測")
      expect(inner.calls).to be_empty
    end

    it "passes other tools to the original provider" do
      expect(provider.call("echo", { "text" => "hi" })).to eq(echoed: "hi")
      expect(inner.calls).to eq([["echo", { "text" => "hi" }]])
      expect(File.exist?(path)).to be(false)
    end

    it "is offered over MCP as a JSON Schema tool and can be called there" do
      server = ClaudeCli::McpServer.new(provider: provider)
      listed = server.handle(JSON.generate(jsonrpc: "2.0", id: 1, method: "tools/list"))[:result][:tools]

      expect(listed.last).to eq(
        name: "long_think",
        description: ClaudeCli::LongThink::DEFINITION[:description],
        inputSchema: {
          type: "object",
          properties: {
            minutes: { type: "number", description: ClaudeCli::LongThink::DEFINITION[:parameters][:properties][:minutes][:description] },
            reason: { type: "string", description: "何をするのか（短く）" },
          },
          required: %w[minutes reason],
        },
      )

      called = server.handle(JSON.generate(jsonrpc: "2.0", id: 2, method: "tools/call",
        params: { name: "long_think", arguments: { minutes: 7, reason: "計測" } }))[:result]
      expect(called[:isError]).to be(false)
      expect(JSON.parse(called[:content].first[:text])).to include("minutes" => 7, "capped" => false)
      expect(long_think.read.minutes).to eq(7)

      called = server.handle(JSON.generate(jsonrpc: "2.0", id: 3, method: "tools/call",
        params: { name: "long_think", arguments: { minutes: 2.5, reason: "計測" } }))[:result]
      expect(JSON.parse(called[:content].first[:text])).to include("minutes" => 3)
    end
  end
end
