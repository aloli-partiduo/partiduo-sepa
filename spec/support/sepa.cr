# SPDX-License-Identifier: AGPL-3.0-or-later

# Exécute le bloc avec une autre liste de modules actifs (`PARTIDUO_MODULES`),
# puis restaure la configuration.
def with_active_modules(codes : String?, &)
  previous = ENV["PARTIDUO_MODULES"]?
  codes.nil? ? ENV.delete("PARTIDUO_MODULES") : (ENV["PARTIDUO_MODULES"] = codes)
  yield
ensure
  previous.nil? ? ENV.delete("PARTIDUO_MODULES") : (ENV["PARTIDUO_MODULES"] = previous)
end

# Valeur attendue présente : échoue clairement sinon (plutôt que `not_nil!`).
def present(value : T?) : T forall T
  value.nil? ? raise("valeur attendue, nil obtenu") : value
end

module Sepa
  # Outils des specs : dossier provisionné par le contrat du cœur (journal
  # financier F01 adossé à sa fiche Banque, dotée d'un IBAN), extension
  # activée, acteurs (préparateur, approbateur), fournisseurs et clients,
  # factures passées par la Comptabilité.
  module SpecSupport
    alias Api = Sepa::Api
    alias Acc = Partiduo::Api::Accounting

    FIXTURES = File.join(ROOT, "spec", "fixtures")

    # IBAN et BIC de test (clés exactes).
    BANK_IBAN     = "FR7630001007941234567890185"
    BANK_BIC      = "BDFEFRPPXXX"
    SUPPLIER_IBAN = "FR7630006000011234567890189"
    GERMAN_IBAN   = "DE89370400440532013000"
    BELGIAN_IBAN  = "BE68539007547034"
    POSTAL_IBAN   = "FR1420041010050500013M02606"
    ICS           = "FR72ZZZ123456"

    # Permissions du cœur de qui compose les lots et passe les règlements.
    CORE_PERMISSIONS = ["core.attachment.read", "core.attachment.write", "accounting.ledger.read", "accounting.entry.read",
                        "accounting.entry.post", "accounting.entry.cancel", "accounting.account.read",
                        "accounting.matching.write", "cards.card.read"]

    def self.system : Partiduo::Api::Actor
      Partiduo::Api::Actor.system
    end

    def self.d(text : String) : BigDecimal
      BigDecimal.new(text)
    end

    def self.date(text : String) : Time
      Time.parse_utc(text, "%Y-%m-%d")
    end

    # Dossier FR, exercice 2026, utilisateurs de test, IBAN de la banque,
    # extension active.
    def self.setup : Nil
      PartiduoUi::Reference.provision
      PartiduoUi::Reference.fiscal_year(2026)
      user("alice@example.com", "Alice")
      user("bruno@example.com", "Bruno")
      bank_iban(BANK_IBAN, BANK_BIC)
      activate
    end

    def self.activate : Nil
      Partiduo::Api::Modules.activate(system, Sepa::CODE).value!
    end

    def self.user(email : String, first_name : String) : Int64
      input = Partiduo::Api::Auth::UserInput.new(email: email, first_name: first_name, last_name: "Test", role: "member",
        profile_id: PartiduoUi::Accounts.profile_id("ADMIN"), password: PartiduoUi::Accounts::PASSWORD)
      Partiduo::Api::Auth.create_user(system, input).value!.user.id
    end

    def self.user_id(email : String) : Int64
      Partiduo::Api::Auth.user_by_email(system, email).try(&.id) || raise "utilisateur #{email} absent"
    end

    # Personne authentifiée au niveau 3, authentification forte récente
    # (exigée pour approuver, A-SEPA-3) sauf `strong_auth_at` donné.
    def self.actor(email : String, permissions : Array(String), strong_auth_at : Time? = Time.utc) : Partiduo::Api::Actor
      Partiduo::Api::Actor.user(user_id(email), permissions, level: 3, strong_auth_at: strong_auth_at)
    end

    # Tous les droits de l'extension (et ceux du cœur qu'elle emploie).
    def self.accountant : Partiduo::Api::Actor
      actor("alice@example.com", [Api::READ, Api::PREPARE, Api::APPROVE, Api::ADMIN] + CORE_PERMISSIONS)
    end

    # Compose et prépare, sans approuver.
    def self.preparer : Partiduo::Api::Actor
      actor("bruno@example.com", [Api::READ, Api::PREPARE] + CORE_PERMISSIONS)
    end

    def self.reader : Partiduo::Api::Actor
      actor("bruno@example.com", [Api::READ, "accounting.ledger.read"])
    end

    def self.bank : Acc::LedgerView
      Acc.ledger_by_code(system, "F01")
    end

    # IBAN et BIC de la fiche Banque du journal F01.
    def self.bank_iban(iban : String, bic : String = "") : Nil
      code = bank.bank_card_code || raise "journal F01 sans fiche Banque"
      card = Partiduo::Api::Cards.card_by_code(system, code) || raise "fiche #{code} absente"
      Partiduo::Api::Cards.update_card(system, card.id, card.to_input.copy_with(iban: iban, bic: bic)).value!
    end

    # Réglages propres à l'extension.
    def self.settings(**changes) : Api::SettingsView
      current = Api.settings(accountant)
      input = Api::SettingsInput.new(settlement_mode: current.settlement_mode, batch_booking: current.batch_booking,
        ledger_id: current.ledger_id)
      Api.update_settings(accountant, input.copy_with(**changes)).value!
    end

    # Configuration de la société, par le contrat du cœur : identifiant
    # créancier SEPA (`creditor_identifier`), validation à une ou deux
    # personnes (`approval_mode`).
    def self.company(**changes) : Partiduo::Api::Core::SettingsView
      current = Partiduo::Api::Core.settings(system)
      Partiduo::Api::Core.update_settings(system, current.to_input.copy_with(**changes)).value!
    end

    # Tiers avec IBAN et adresse (ville et pays : adresse hybride).
    def self.party(category : String, name : String, code : String, iban : String = "", bic : String = "",
                   city : String = "") : Partiduo::Api::Cards::CardView
      found = PartiduoUi::Reference.category(category)
      address = city.empty? ? nil : Partiduo::Api::Cards::AddressInput.new(line1: "12 rue de l'Église", postcode: "69002",
        city: city, country_code: "FR")
      input = Partiduo::Api::Cards::CardInput.new(category_id: found.id, name: name, code: code, iban: iban, bic: bic,
        address: address)
      Partiduo::Api::Cards.create_card(system, input).value!
    end

    def self.supplier(name : String, code : String, iban : String = SUPPLIER_IBAN, bic : String = "",
                      city : String = "") : Partiduo::Api::Cards::CardView
      party("SUPPLIER", name, code, iban, bic, city)
    end

    def self.customer(name : String, code : String) : Partiduo::Api::Cards::CardView
      party("CUSTOMER", name, code)
    end

    # Facture d'achat de `amount` HT (TVA normale) du fournisseur `code`.
    def self.purchase(code : String, amount : String, day : String = "2026-09-15", due : String? = nil) : Acc::EntryView
      input = Acc::DocumentInput.new(ledger_id: Acc.ledger_by_code(system, "A01").id, date: date(day), third_party: code,
        lines: [Acc::DocumentLineInput.new(amount: d(amount), account: "627", vat_rate: "NOR")],
        due_date: due.try { |text| date(text) }, label: "Facture #{code}")
      Acc.post_purchase(system, input).value!
    end

    def self.sale(code : String, amount : String, day : String = "2026-09-15") : Acc::EntryView
      PartiduoUi::Books.sale(code, amount, day)
    end

    def self.line_of(entry : Acc::EntryView, code : String) : Acc::EntryLineView
      entry.lines.find! { |line| line.card_code == code }
    end

    def self.batch(kind : String = "transfer", day : String = "2026-10-09", actor : Partiduo::Api::Actor = preparer,
                   label : String = "Fournisseurs octobre") : Api::BatchView
      Api.create_batch(actor, Api::BatchInput.new(kind: kind, ledger_id: bank.id, requested_on: date(day), label: label)).value!
    end

    def self.mandate(code : String, iban : String = BELGIAN_IBAN, signed : String = "2026-01-15", kind : String = "recurrent",
                     rum : String = "") : Api::MandateView
      input = Api::MandateInput.new(card_code: code, signed_on: date(signed), iban: iban, rum: rum, kind: kind)
      Api.create_mandate(accountant, input).value!
    end

    # Contenu du fichier d'un lot approuvé.
    def self.xml(batch_id : Int64) : String
      found = Api.file(accountant, batch_id) || raise "lot #{batch_id} sans fichier"
      String.new(found[2])
    end
  end
end
