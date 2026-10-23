# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"
require "../../lib/partiduo-ui-bulma/scripts/api_boundary"

private def source_files(pattern : String) : Array(String)
  Dir.glob(File.join(Sepa::SpecSupport::ROOT, pattern)).reject(&.includes?("/lib/")).sort!
end

describe "Conventions de l'extension SEPA" do
  it "ouvre chaque fichier source par l'en-tête SPDX" do
    missing = (source_files("{src,ui,spec,config,scripts}/**/*.cr") + source_files("*.cr")).reject do |path|
      File.read_lines(path).first? == "# SPDX-License-Identifier: AGPL-3.0-or-later"
    end
    missing += source_files("ui/**/*.html").reject do |path|
      File.read(path).starts_with?("{# SPDX-License-Identifier: AGPL-3.0-or-later")
    end
    missing += source_files("ui/**/*.{js,css}").reject do |path|
      File.read(path).includes?("SPDX-License-Identifier: AGPL-3.0-or-later")
    end
    missing.should be_empty
  end

  it "ne cite le logiciel d'origine que dans la documentation (*.adoc, *.md)" do
    root = Sepa::SpecSupport::ROOT
    name = "noa" + "lyss"
    offenders = Dir.glob(File.join(root, "**", "*")).reject do |path|
      path.includes?("/lib/") || path.includes?("/bin/") || path.includes?("/tmp/") || path.ends_with?(".adoc") ||
        path.ends_with?(".md") || File.directory?(path)
    end.select { |path| File.read(path).downcase.includes?(name) rescue false }
    offenders.should be_empty
  end

  it "a les mêmes clés de traduction dans chaque langue livrée, aux mêmes interpolations" do
    %w[src/sepa/locales ui/bulma/locales].flat_map do |dir|
      PartiduoUi::Translations.parity_failures(File.join(Sepa::SpecSupport::ROOT, dir))
    end.should eq([] of String)
  end

  it "traduit dans chaque langue livrée toute clé passée à I18n.t ou {% translate %} (cœur, interface, extension)" do
    PartiduoUi::Translations.unknown_keys(Sepa::SpecSupport::ROOT, %w[src/**/*.cr ui/**/*.cr ui/**/*.html]).should eq([] of String)
  end

  it "traduit toute clé citée par le code et les gabarits de l'extension" do
    cited = source_files("{src,ui}/**/*.{cr,html}").flat_map do |path|
      File.read(path).scan(/["'](sepa(?:_ui)?\.[a-z_]+(?:\.[a-z_]+)+)["']/).map(&.[1])
    end.uniq! - Partiduo::Modules[Sepa::CODE].permissions
    cited.size.should be > 50
    missing = Partiduo::LOCALES.flat_map do |locale|
      I18n.with_locale(locale) do
        cited.select { |key| I18n.t(key).includes?("missing") && I18n.t("#{key}.one").includes?("missing") }
          .map { |key| "#{locale}:#{key}" }
      end
    end
    missing.should be_empty
  end

  it "traduit toute clé d'erreur du contrat (sepa.errors.*) dans chaque langue livrée" do
    cited = source_files("src/**/*.cr").flat_map do |path|
      text = File.read(path)
      text.scan(/error\([^()]*?, "([a-z_]+(?:\.[a-z_]+)+)"/).map(&.[1]) + text.scan(/issue\(\w+, "([a-z_]+(?:\.[a-z_]+)+)"/).map(&.[1])
    end.uniq!
    cited.size.should be > 30
    missing = Partiduo::LOCALES.flat_map do |locale|
      I18n.with_locale(locale) do
        cited.select { |key| I18n.t("sepa.errors.#{key}").includes?("missing") }.map { |key| "#{locale}:#{key}" }
      end
    end
    missing.should be_empty
  end

  it "traduit chaque genre, statut, mode, séquence et état de règlement" do
    {
      "sepa.kinds"            => Sepa::Api::KINDS,
      "sepa.statuses"         => Sepa::Api::STATUSES,
      "sepa.approval_modes"   => Sepa::Api::APPROVAL_MODES,
      "sepa.settlement_modes" => Sepa::Api::SETTLEMENT_MODES,
      "sepa.mandate_kinds"    => Sepa::Api::MANDATE_KINDS,
      "sepa.mandate_statuses" => Sepa::Api::MANDATE_STATUSES,
      "sepa.sequences"        => Sepa::Api::SEQUENCES,
      "sepa.settlements"      => Sepa::Api::SETTLEMENTS,
    }.each do |scope, codes|
      Partiduo::LOCALES.each do |locale|
        I18n.with_locale(locale) { codes.each { |code| I18n.t("#{scope}.#{code}").should_not contain("missing") } }
      end
    end
    %w[candidate_iban_blank candidate_iban_invalid].each do |key|
      Partiduo::LOCALES.each do |locale|
        I18n.with_locale(locale) { I18n.t("sepa.errors.item.#{key}").should_not contain("missing") }
      end
    end
  end

  it "écrit ses montants en BigDecimal, jamais en flottant" do
    source_files("{src,ui}/**/*.cr").flat_map do |path|
      File.read_lines(path).each_with_index(1).compact_map do |line, number|
        "#{path}:#{number}" if ApiBoundary.strip_comment(line).matches?(/\bFloat(32|64)?\b|\.to_f\b/)
      end
    end.should be_empty
  end

  it "écrit ses feuilles de style en propriétés logiques, avec les jetons du thème (ADR-005 D7)" do
    physical = /(?:margin|padding|border)-(?:left|right|top|bottom)\b|\b(?:left|right)\s*:|text-align:\s*(?:left|right)|float:\s*(?:left|right)/
    source_files("ui/**/*.css").each do |path|
      File.read(path).scan(physical).map(&.[0]).should eq([] of String)
      File.read(path).scan(/#[0-9a-fA-F]{3,6}\b|rgba?\(/).map(&.[0]).should eq([] of String)
    end
  end

  it "ne parle au cœur, depuis ui/bulma, que par Partiduo::Api (ADR-005 D3)" do
    root = Sepa::SpecSupport::ROOT
    ApiBoundary.scan([File.join(root, "ui")], base: root).map(&.to_s).should eq([] of String)
  end

  it "ne parle au métier de l'extension, depuis ui/bulma, que par Sepa::Api (ADR-005 D4)" do
    allowed = %w[Api Ui CODE VERSION]
    leaks = source_files("ui/**/*.cr").flat_map do |path|
      File.read_lines(path).each_with_index(1).flat_map do |line, number|
        ApiBoundary.strip_comment(line).scan(/(?<![\w:])Sepa::([A-Za-z_]\w*)/).compact_map do |match|
          "#{path.lchop(Sepa::SpecSupport::ROOT + "/")}:#{number} Sepa::#{match[1]}" unless allowed.includes?(match[1])
        end
      end
    end
    leaks.should be_empty
  end

  it "n'utilise que des icônes de la planche de l'interface (ADR-005 D5)" do
    lucide = File.join(Sepa::SpecSupport::ROOT, "lib", "partiduo-ui-bulma", "icons", "lucide")
    known = Dir.glob(File.join(lucide, "*.svg")).map { |path| File.basename(path, ".svg") }
    known.should_not be_empty
    used = source_files("ui/bulma/templates/**/*.html").flat_map do |path|
      File.read(path).scan(/_icon\.html" with name="([a-z0-9-]+)"/).map { |match| "#{path.lchop(Sepa::SpecSupport::ROOT + "/")} #{match[1]}" }
    end
    used += source_files("ui/**/*.cr").flat_map do |path|
      File.read(path).scan(/_action\("[^"]+", [^\n]*?, "(?:primary|danger|)", "([a-z0-9-]+)"\)/).map { |match| "#{path} #{match[1]}" }
    end
    used.reject { |item| known.includes?(item.split(' ').last) }.should be_empty
  end
end
