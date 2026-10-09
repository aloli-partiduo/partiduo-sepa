# SPDX-License-Identifier: AGPL-3.0-or-later

module Sepa
  # Production des fichiers ISO 20022 (D-SEPA-001) : `pain.001.001.09`
  # (virements, une seule information de paiement) et `pain.008.001.08`
  # (prélèvements SDD Core, une information de paiement par séquence FRST,
  # RCUR, OOFF), selon les guides de mise en œuvre client-banque de l'EPC.
  # Textes translittérés au jeu SEPA ; montants au centime, écrits depuis
  # `BigDecimal` ; BIC facultatif (`NOTPROVIDED` pour l'agent du donneur
  # d'ordre sans BIC) ; adresse hybride (ville et pays structurés, deux
  # lignes libres au plus), seule admise par les banques après le 15
  # novembre 2026 avec l'adresse structurée. Interne.
  module XmlBuilder
    TRANSFER_NS = "urn:iso:std:iso:20022:tech:xsd:#{Api::TRANSFER_SCHEMA}"
    DEBIT_NS    = "urn:iso:std:iso:20022:tech:xsd:#{Api::DEBIT_SCHEMA}"
    XSI_NS      = "http://www.w3.org/2001/XMLSchema-instance"

    # Ce qu'il faut pour écrire un fichier : le lot figé, ses paiements, le
    # compte, l'ICS, l'identifiant du message et l'heure de création.
    record Input,
      batch : Batch,
      items : Array(Item),
      account : Preparation::Account,
      creditor_identifier : String,
      message_id : String,
      created_at : Time,
      addresses : Hash(String, Partiduo::Api::Cards::AddressView) = {} of String => Partiduo::Api::Cards::AddressView

    # Identifiant du message : `PDSEPA-<lot>-<AAAAMMJJHHMMSS>`.
    def self.message_id(batch_id : Int64, at : Time) : String
      "PDSEPA-#{batch_id}-#{at.to_s("%Y%m%d%H%M%S")}"
    end

    def self.build(input : Input) : String
      input.batch.kind == "debit" ? debit(input) : transfer(input)
    end

    # Montant au centime, point décimal (`1234.50`).
    def self.amount(value : BigDecimal) : String
      whole, _, cents = value.round(2).to_s.partition('.')
      "#{whole}.#{cents.ljust(2, '0')[0, 2]}"
    end

    def self.total(items : Array(Item)) : BigDecimal
      items.sum(BigDecimal.new(0), &.amount!)
    end

    # --- Virements (pain.001.001.09) ------------------------------------------------

    private def self.transfer(input : Input) : String
      batch = input.batch
      XML.build(encoding: "UTF-8", indent: "  ") do |xml|
        xml.element("Document", xmlns: TRANSFER_NS, "xmlns:xsi": XSI_NS) do
          xml.element("CstmrCdtTrfInitn") do
            group_header(xml, input, input.items)
            xml.element("PmtInf") do
              xml.element("PmtInfId") { xml.text "#{input.message_id}-1" }
              xml.element("PmtMtd") { xml.text "TRF" }
              xml.element("BtchBookg") { xml.text batch.batch_booking == true ? "true" : "false" }
              xml.element("NbOfTxs") { xml.text input.items.size.to_s }
              xml.element("CtrlSum") { xml.text amount(total(input.items)) }
              xml.element("PmtTpInf") { xml.element("SvcLvl") { xml.element("Cd") { xml.text "SEPA" } } }
              xml.element("ReqdExctnDt") { xml.element("Dt") { xml.text batch.requested_on!.to_s("%Y-%m-%d") } }
              xml.element("Dbtr") { xml.element("Nm") { xml.text input.account.name } }
              account(xml, "DbtrAcct", input.account.iban)
              agent(xml, "DbtrAgt", input.account.bic, required: true)
              xml.element("ChrgBr") { xml.text "SLEV" }
              input.items.each { |item| credit_transfer(xml, item, input) }
            end
          end
        end
      end
    end

    private def self.credit_transfer(xml : XML::Builder, item : Item, input : Input) : Nil
      xml.element("CdtTrfTxInf") do
        xml.element("PmtId") { xml.element("EndToEndId") { xml.text item.end_to_end_id.to_s } }
        xml.element("Amt") { xml.element("InstdAmt", Ccy: "EUR") { xml.text amount(item.amount!) } }
        agent(xml, "CdtrAgt", item.bic.to_s, required: false)
        party(xml, "Cdtr", item.name.to_s, input.addresses[item.card_code.to_s]?)
        account(xml, "CdtrAcct", item.iban.to_s)
        remittance(xml, item.remittance.to_s)
      end
    end

    # --- Prélèvements (pain.008.001.08) ---------------------------------------------

    private def self.debit(input : Input) : String
      batch = input.batch
      groups = input.items.group_by(&.sequence_type.to_s)
      XML.build(encoding: "UTF-8", indent: "  ") do |xml|
        xml.element("Document", xmlns: DEBIT_NS, "xmlns:xsi": XSI_NS) do
          xml.element("CstmrDrctDbtInitn") do
            group_header(xml, input, input.items)
            Api::SEQUENCES.each do |sequence|
              items = groups[sequence]? || next
              xml.element("PmtInf") do
                xml.element("PmtInfId") { xml.text "#{input.message_id}-#{sequence}" }
                xml.element("PmtMtd") { xml.text "DD" }
                xml.element("BtchBookg") { xml.text batch.batch_booking == true ? "true" : "false" }
                xml.element("NbOfTxs") { xml.text items.size.to_s }
                xml.element("CtrlSum") { xml.text amount(total(items)) }
                xml.element("PmtTpInf") do
                  xml.element("SvcLvl") { xml.element("Cd") { xml.text "SEPA" } }
                  xml.element("LclInstrm") { xml.element("Cd") { xml.text "CORE" } }
                  xml.element("SeqTp") { xml.text sequence }
                end
                xml.element("ReqdColltnDt") { xml.text batch.requested_on!.to_s("%Y-%m-%d") }
                xml.element("Cdtr") { xml.element("Nm") { xml.text input.account.name } }
                account(xml, "CdtrAcct", input.account.iban)
                agent(xml, "CdtrAgt", input.account.bic, required: true)
                xml.element("ChrgBr") { xml.text "SLEV" }
                xml.element("CdtrSchmeId") do
                  xml.element("Id") do
                    xml.element("PrvtId") do
                      xml.element("Othr") do
                        xml.element("Id") { xml.text input.creditor_identifier }
                        xml.element("SchmeNm") { xml.element("Prtry") { xml.text "SEPA" } }
                      end
                    end
                  end
                end
                items.each { |item| direct_debit(xml, item, input) }
              end
            end
          end
        end
      end
    end

    private def self.direct_debit(xml : XML::Builder, item : Item, input : Input) : Nil
      xml.element("DrctDbtTxInf") do
        xml.element("PmtId") { xml.element("EndToEndId") { xml.text item.end_to_end_id.to_s } }
        xml.element("InstdAmt", Ccy: "EUR") { xml.text amount(item.amount!) }
        xml.element("DrctDbtTx") do
          xml.element("MndtRltdInf") do
            xml.element("MndtId") { xml.text item.mandate_rum.to_s }
            xml.element("DtOfSgntr") { xml.text item.mandate_signed_on.try(&.to_s("%Y-%m-%d")) || "" }
            unless item.original_iban.to_s.empty?
              xml.element("AmdmntInd") { xml.text "true" }
              xml.element("AmdmntInfDtls") { account(xml, "OrgnlDbtrAcct", item.original_iban.to_s) }
            end
          end
        end
        agent(xml, "DbtrAgt", item.bic.to_s, required: true)
        party(xml, "Dbtr", item.name.to_s, input.addresses[item.card_code.to_s]?)
        account(xml, "DbtrAcct", item.iban.to_s)
        remittance(xml, item.remittance.to_s)
      end
    end

    # --- Éléments communs -------------------------------------------------------------

    private def self.group_header(xml : XML::Builder, input : Input, items : Array(Item)) : Nil
      xml.element("GrpHdr") do
        xml.element("MsgId") { xml.text input.message_id }
        xml.element("CreDtTm") { xml.text input.created_at.to_utc.to_s("%Y-%m-%dT%H:%M:%S") }
        xml.element("NbOfTxs") { xml.text items.size.to_s }
        xml.element("CtrlSum") { xml.text amount(total(items)) }
        xml.element("InitgPty") { xml.element("Nm") { xml.text input.account.name } }
      end
    end

    private def self.account(xml : XML::Builder, tag : String, iban : String) : Nil
      xml.element(tag) { xml.element("Id") { xml.element("IBAN") { xml.text iban } } }
    end

    # Agent (banque) : BIC, ou `NOTPROVIDED` quand l'élément est exigé et
    # que le BIC n'est pas connu (règle « IBAN seul » de l'EPC).
    private def self.agent(xml : XML::Builder, tag : String, bic : String, required : Bool) : Nil
      return if bic.empty? && !required
      xml.element(tag) do
        xml.element("FinInstnId") do
          if bic.empty?
            xml.element("Othr") { xml.element("Id") { xml.text "NOTPROVIDED" } }
          else
            xml.element("BICFI") { xml.text bic }
          end
        end
      end
    end

    # Tiers : nom et, si la fiche a une ville et un pays, adresse hybride.
    private def self.party(xml : XML::Builder, tag : String, name : String, address : Partiduo::Api::Cards::AddressView?) : Nil
      xml.element(tag) do
        xml.element("Nm") { xml.text name }
        if address && (town = Charset.transliterate(address.city, 35).presence) && address.country_code.matches?(/\A[A-Z]{2}\z/)
          xml.element("PstlAdr") do
            postcode = Charset.transliterate(address.postcode, 16)
            xml.element("PstCd") { xml.text postcode } unless postcode.empty?
            xml.element("TwnNm") { xml.text town }
            xml.element("Ctry") { xml.text address.country_code }
            [address.line1, address.line2].map { |line| Charset.transliterate(line, 70) }.reject(&.empty?).first(2).each do |line|
              xml.element("AdrLine") { xml.text line }
            end
          end
        end
      end
    end

    # Communication : référence RF (ISO 11649) ou communication structurée
    # belge en `Strd`, texte libre en `Ustrd`.
    private def self.remittance(xml : XML::Builder, text : String) : Nil
      return if text.empty?
      xml.element("RmtInf") do
        case Codes.reference_kind(text)
        when "rf"
          structured(xml, "ISO", Codes.compact(text))
        when "bba"
          structured(xml, "BBA", Codes.belgian_reference(text).to_s)
        else
          xml.element("Ustrd") { xml.text text }
        end
      end
    end

    private def self.structured(xml : XML::Builder, issuer : String, reference : String) : Nil
      xml.element("Strd") do
        xml.element("CdtrRefInf") do
          xml.element("Tp") do
            xml.element("CdOrPrtry") { xml.element("Cd") { xml.text "SCOR" } }
            xml.element("Issr") { xml.text issuer }
          end
          xml.element("Ref") { xml.text reference }
        end
      end
    end
  end
end
