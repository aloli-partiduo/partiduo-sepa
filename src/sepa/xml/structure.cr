# SPDX-License-Identifier: AGPL-3.0-or-later

module Sepa
  # Contrôle structurel d'un fichier produit (D-SEPA-012), relu comme le
  # lirait la banque : espace de noms, ordre et nombre des éléments de la
  # partie des schémas ISO 20022 qu'emploient les guides de l'EPC, valeurs
  # (identifiants, IBAN, BIC, ICS, dates, montants, jeu de caractères,
  # longueurs) et cohérence des totaux de contrôle. Ce n'est pas le XSD
  # officiel, dont la licence n'en permet pas la redistribution ici : quand
  # l'exploitant le dépose (`PARTIDUO_SEPA_XSD_DIR`), `Schema` valide en plus
  # le fichier contre lui. Interne.
  module Structure
    # Enfant admis : nom, minimum, maximum (`nil` : sans limite).
    alias Child = {String, Int32, Int32?}

    ACCOUNT  = [{"Id", 1, 1}, {"Ccy", 0, 1}] of Child
    AGENT    = [{"FinInstnId", 1, 1}] of Child
    PARTY    = [{"Nm", 1, 1}, {"PstlAdr", 0, 1}] of Child
    ADDRESS  = [{"PstCd", 0, 1}, {"TwnNm", 0, 1}, {"Ctry", 0, 1}, {"AdrLine", 0, 7}] of Child
    REMIT    = [{"Ustrd", 0, 1}, {"Strd", 0, 1}] of Child
    SVC_LVL  = [{"Cd", 1, 1}] of Child
    INITG    = [{"Nm", 0, 1}] of Child
    HEADER   = [{"MsgId", 1, 1}, {"CreDtTm", 1, 1}, {"NbOfTxs", 1, 1}, {"CtrlSum", 0, 1}, {"InitgPty", 1, 1}] of Child
    FIN_INST = [{"BICFI", 0, 1}, {"Othr", 0, 1}] of Child

    # Contenu attendu, par élément (`parent/élément` d'abord, puis
    # `élément`).
    RULES = {
      "Document"                => [{"CstmrCdtTrfInitn", 0, 1}, {"CstmrDrctDbtInitn", 0, 1}] of Child,
      "CstmrCdtTrfInitn"        => [{"GrpHdr", 1, 1}, {"PmtInf", 1, nil}] of Child,
      "CstmrDrctDbtInitn"       => [{"GrpHdr", 1, 1}, {"PmtInf", 1, nil}] of Child,
      "GrpHdr"                  => HEADER,
      "InitgPty"                => INITG,
      "CstmrCdtTrfInitn/PmtInf" => [{"PmtInfId", 1, 1}, {"PmtMtd", 1, 1}, {"BtchBookg", 0, 1}, {"NbOfTxs", 0, 1},
                                    {"CtrlSum", 0, 1}, {"PmtTpInf", 0, 1}, {"ReqdExctnDt", 1, 1}, {"Dbtr", 1, 1},
                                    {"DbtrAcct", 1, 1}, {"DbtrAgt", 1, 1}, {"ChrgBr", 0, 1},
                                    {"CdtTrfTxInf", 1, nil}] of Child,
      "CstmrDrctDbtInitn/PmtInf" => [{"PmtInfId", 1, 1}, {"PmtMtd", 1, 1}, {"BtchBookg", 0, 1}, {"NbOfTxs", 0, 1},
                                     {"CtrlSum", 0, 1}, {"PmtTpInf", 1, 1}, {"ReqdColltnDt", 1, 1}, {"Cdtr", 1, 1},
                                     {"CdtrAcct", 1, 1}, {"CdtrAgt", 1, 1}, {"ChrgBr", 0, 1}, {"CdtrSchmeId", 1, 1},
                                     {"DrctDbtTxInf", 1, nil}] of Child,
      "CdtTrfTxInf/PmtTpInf" => [{"SvcLvl", 0, 1}] of Child,
      "PmtInf/PmtTpInf"      => [{"SvcLvl", 1, 1}, {"LclInstrm", 0, 1}, {"SeqTp", 0, 1}] of Child,
      "SvcLvl"               => SVC_LVL,
      "LclInstrm"            => SVC_LVL,
      "ReqdExctnDt"          => [{"Dt", 1, 1}] of Child,
      "Dbtr"                 => PARTY,
      "Cdtr"                 => PARTY,
      "PstlAdr"              => ADDRESS,
      "DbtrAcct"             => ACCOUNT,
      "CdtrAcct"             => ACCOUNT,
      "OrgnlDbtrAcct"        => ACCOUNT,
      "DbtrAcct/Id"          => [{"IBAN", 1, 1}] of Child,
      "CdtrAcct/Id"          => [{"IBAN", 1, 1}] of Child,
      "OrgnlDbtrAcct/Id"     => [{"IBAN", 1, 1}] of Child,
      "DbtrAgt"              => AGENT,
      "CdtrAgt"              => AGENT,
      "FinInstnId"           => FIN_INST,
      "FinInstnId/Othr"      => [{"Id", 1, 1}] of Child,
      "CdtTrfTxInf"          => [{"PmtId", 1, 1}, {"Amt", 1, 1}, {"CdtrAgt", 0, 1}, {"Cdtr", 1, 1},
                        {"CdtrAcct", 1, 1}, {"RmtInf", 0, 1}] of Child,
      "PmtId"        => [{"EndToEndId", 1, 1}] of Child,
      "Amt"          => [{"InstdAmt", 1, 1}] of Child,
      "DrctDbtTxInf" => [{"PmtId", 1, 1}, {"InstdAmt", 1, 1}, {"DrctDbtTx", 1, 1}, {"DbtrAgt", 1, 1},
                         {"Dbtr", 1, 1}, {"DbtrAcct", 1, 1}, {"RmtInf", 0, 1}] of Child,
      "DrctDbtTx"   => [{"MndtRltdInf", 1, 1}] of Child,
      "MndtRltdInf" => [{"MndtId", 1, 1}, {"DtOfSgntr", 1, 1}, {"AmdmntInd", 0, 1},
                        {"AmdmntInfDtls", 0, 1}] of Child,
      "AmdmntInfDtls"  => [{"OrgnlDbtrAcct", 0, 1}] of Child,
      "CdtrSchmeId"    => [{"Id", 1, 1}] of Child,
      "CdtrSchmeId/Id" => [{"PrvtId", 1, 1}] of Child,
      "PrvtId"         => [{"Othr", 1, 1}] of Child,
      "PrvtId/Othr"    => [{"Id", 1, 1}, {"SchmeNm", 1, 1}] of Child,
      "SchmeNm"        => [{"Prtry", 1, 1}] of Child,
      "RmtInf"         => REMIT,
      "Strd"           => [{"CdtrRefInf", 1, 1}] of Child,
      "CdtrRefInf"     => [{"Tp", 1, 1}, {"Ref", 1, 1}] of Child,
      "Tp"             => [{"CdOrPrtry", 1, 1}, {"Issr", 0, 1}] of Child,
      "CdOrPrtry"      => [{"Cd", 1, 1}] of Child,
    }

    DATE = /\A\d{4}-\d{2}-\d{2}\z/

    # Problèmes relevés (`chemin : message`), vide si le fichier est conforme.
    def self.problems(content : String, kind : String) : Array(String)
      problems = [] of String
      document = begin
        XML.parse(content, XML::ParserOptions::NONET)
      rescue ex : XML::Error
        return ["XML illisible : #{ex.message}"]
      end
      root = document.root || return ["document vide"]
      expected = kind == "debit" ? XmlBuilder::DEBIT_NS : XmlBuilder::TRANSFER_NS
      problems << "Document : espace de noms #{root.namespace.try(&.href)} au lieu de #{expected}" unless root.name == "Document" && root.namespace.try(&.href) == expected
      walk(root, nil, "Document", problems)
      totals(root, problems)
      problems
    end

    private def self.elements(node : XML::Node) : Array(XML::Node)
      node.children.select(&.element?)
    end

    private def self.walk(node : XML::Node, parent : String?, path : String, problems : Array(String)) : Nil
      name = node.name
      rule = (parent ? RULES["#{parent}/#{name}"]? : nil) || RULES[name]?
      children = elements(node)
      if rule.nil?
        problems << "#{path} : contenu inattendu" unless children.empty?
        leaf(node, parent, path, problems)
        return
      end
      problems << "#{path} : texte inattendu" unless node.children.all? { |child| child.element? || child.content.strip.empty? }
      sequence(children, rule, path, problems)
      children.each_with_index { |child, index| walk(child, name, "#{path}/#{child.name}[#{index + 1}]", problems) }
    end

    # Ordre et cardinalité des enfants selon la règle.
    private def self.sequence(children : Array(XML::Node), rule : Array(Child), path : String, problems : Array(String)) : Nil
      index = 0
      rule.each do |(tag, min, max)|
        count = 0
        while index < children.size && children[index].name == tag
          count += 1
          index += 1
        end
        problems << "#{path} : #{tag} attendu au moins #{min} fois" if count < min
        problems << "#{path} : #{tag} au plus #{max} fois" if max && count > max
      end
      problems << "#{path} : #{children[index].name} inattendu ou mal placé" if index < children.size
    end

    # Contrôle de la valeur d'un élément simple : (texte, élément, parent)
    # → message, ou `nil` si la valeur est admise.
    alias Check = Proc(String, XML::Node, String?, String?)

    def self.text_check(max : Int32, message : String) : Check
      Check.new { |text, _, _| message unless text.size.in?(1..max) && Charset.valid?(text) }
    end

    def self.pattern_check(pattern : Regex, message : String) : Check
      Check.new { |text, _, _| message unless text.matches?(pattern) }
    end

    def self.choice_check(values : Array(String), message : String) : Check
      Check.new { |text, _, _| message unless values.includes?(text) }
    end

    IDENTIFIER = Check.new { |text, _, _| "identifiant non conforme" unless Charset.valid_identifier?(text) }
    ISO_DATE   = Check.new { |text, _, _| "date attendue" unless text.matches?(DATE) && (Time.parse_utc(text, "%Y-%m-%d") rescue nil) }
    BOOLEAN    = choice_check(%w[true false], "booléen attendu")

    # Codes admis selon l'élément parent d'un `Cd`.
    CODES = {"SvcLvl" => ["SEPA"], "LclInstrm" => ["CORE"], "CdOrPrtry" => ["SCOR"]}

    LEAVES = {
      "MsgId"        => IDENTIFIER,
      "PmtInfId"     => IDENTIFIER,
      "EndToEndId"   => IDENTIFIER,
      "MndtId"       => IDENTIFIER,
      "CreDtTm"      => pattern_check(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\z/, "date et heure attendues"),
      "Dt"           => ISO_DATE,
      "ReqdColltnDt" => ISO_DATE,
      "DtOfSgntr"    => ISO_DATE,
      "NbOfTxs"      => pattern_check(/\A[0-9]{1,15}\z/, "nombre attendu"),
      "CtrlSum"      => pattern_check(/\A[0-9]{1,16}\.[0-9]{2}\z/, "montant attendu"),
      "InstdAmt"     => Check.new do |text, node, _|
        if !text.matches?(/\A[0-9]{1,9}\.[0-9]{2}\z/) || BigDecimal.new(text) <= 0
          "montant attendu"
        elsif node["Ccy"]? != "EUR"
          "devise EUR attendue"
        end
      end,
      "IBAN"  => Check.new { |text, _, _| "IBAN invalide" unless Codes.valid_iban?(text) && text == Codes.compact(text) },
      "BICFI" => Check.new { |text, _, _| "BIC invalide" unless Codes.valid_bic?(text) && text == Codes.compact(text) },
      "Id"    => Check.new do |text, _, parent|
        "identifiant non conforme" if parent == "Othr" && text != "NOTPROVIDED" && !Codes.valid_ics?(text)
      end,
      "Nm"        => text_check(70, "nom vide, trop long ou hors du jeu SEPA"),
      "Ustrd"     => text_check(140, "communication trop longue ou hors du jeu SEPA"),
      "TwnNm"     => text_check(35, "ville trop longue ou hors du jeu SEPA"),
      "AdrLine"   => text_check(70, "ligne d'adresse trop longue ou hors du jeu SEPA"),
      "PstCd"     => text_check(16, "code postal non conforme"),
      "Ctry"      => pattern_check(/\A[A-Z]{2}\z/, "code pays attendu"),
      "PmtMtd"    => choice_check(%w[TRF DD], "TRF ou DD attendu"),
      "BtchBookg" => BOOLEAN,
      "AmdmntInd" => BOOLEAN,
      "ChrgBr"    => choice_check(%w[SLEV], "SLEV attendu"),
      "SeqTp"     => choice_check(Api::SEQUENCES, "séquence inconnue"),
      "Cd"        => Check.new { |text, _, parent| "code inattendu" if (allowed = CODES[parent]?) && !allowed.includes?(text) },
      "Prtry"     => choice_check(%w[SEPA], "SEPA attendu"),
      "Issr"      => choice_check(%w[ISO BBA], "émetteur inconnu"),
      "Ref"       => Check.new do |text, _, _|
        "référence structurée invalide" unless Codes.valid_rf?(text) || Codes.belgian_reference(text) == text
      end,
    }

    # Valeur d'un élément simple.
    private def self.leaf(node : XML::Node, parent : String?, path : String, problems : Array(String)) : Nil
      text = node.content
      message = LEAVES[node.name]?.try(&.call(text, node, parent)) || (LEAVES.has_key?(node.name) ? nil : "élément inconnu")
      problems << "#{path} : #{message} (#{text})" if message
    end

    # Nombres et totaux de contrôle de l'en-tête et de chaque information
    # de paiement.
    private def self.totals(root : XML::Node, problems : Array(String)) : Nil
      initiation = elements(root).first? || return
      header = elements(initiation).find(&.name.==("GrpHdr")) || return
      infos = elements(initiation).select(&.name.==("PmtInf"))
      all = [] of BigDecimal
      infos.each_with_index(1) do |info, index|
        amounts = transactions(info).map { |tx| amount_of(tx) }
        all.concat(amounts)
        check(info, amounts, "PmtInf[#{index}]", problems)
      end
      check(header, all, "GrpHdr", problems)
    end

    private def self.transactions(info : XML::Node) : Array(XML::Node)
      elements(info).select(&.name.in?("CdtTrfTxInf", "DrctDbtTxInf"))
    end

    private def self.amount_of(tx : XML::Node) : BigDecimal
      node = elements(tx).find(&.name.==("InstdAmt")) ||
             elements(tx).find(&.name.==("Amt")).try { |amt| elements(amt).find(&.name.==("InstdAmt")) }
      text = node.try(&.content) || "0"
      text.matches?(/\A[0-9]+(\.[0-9]+)?\z/) ? BigDecimal.new(text) : BigDecimal.new(0)
    end

    private def self.check(node : XML::Node, amounts : Array(BigDecimal), path : String, problems : Array(String)) : Nil
      count = elements(node).find(&.name.==("NbOfTxs")).try(&.content)
      problems << "#{path} : NbOfTxs #{count} pour #{amounts.size} paiements" if count && count != amounts.size.to_s
      sum = elements(node).find(&.name.==("CtrlSum")).try(&.content)
      if sum && sum.matches?(/\A[0-9]+\.[0-9]{2}\z/) && BigDecimal.new(sum) != amounts.sum(BigDecimal.new(0))
        problems << "#{path} : CtrlSum #{sum} au lieu de #{XmlBuilder.amount(amounts.sum(BigDecimal.new(0)))}"
      end
    end
  end
end
