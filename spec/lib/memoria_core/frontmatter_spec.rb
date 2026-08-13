require "rails_helper"

RSpec.describe MemoriaCore::Frontmatter do
  describe ".parse" do
    it "parses frontmatter and body" do
      content = <<~MD
        ---
        title: Test
        tags:
          - foo
          - bar
        ---

        Body content here
      MD

      fm, body = described_class.parse(content)

      expect(fm["title"]).to eq("Test")
      expect(fm["tags"]).to eq(["foo", "bar"])
      expect(body).to include("Body content here")
    end

    it "returns nil frontmatter for content without frontmatter" do
      fm, body = described_class.parse("Just plain text")

      expect(fm).to be_nil
      expect(body).to eq("Just plain text")
    end

    it "returns nil frontmatter for empty content" do
      fm, body = described_class.parse("")
      expect(fm).to be_nil
    end

    it "returns nil frontmatter for nil content" do
      fm, body = described_class.parse(nil)
      expect(fm).to be_nil
    end

    it "handles YAML with Date/Time types" do
      content = <<~MD
        ---
        date: 2025-01-15 10:30
        ---

        Body
      MD

      fm, _ = described_class.parse(content)
      expect(fm["date"]).to be_a(Time).or be_a(Date).or be_a(String)
    end
  end

  describe ".build" do
    it "creates markdown with frontmatter" do
      fm = { "title" => "Test", "tags" => ["a", "b"] }
      body = "# Hello\n\nWorld"

      result = described_class.build(fm, body)

      expect(result).to start_with("---\n")
      expect(result).to include("title: Test")
      expect(result).to include("# Hello")
    end
  end
end
