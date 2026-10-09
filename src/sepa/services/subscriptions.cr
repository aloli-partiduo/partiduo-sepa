# SPDX-License-Identifier: AGPL-3.0-or-later

module Sepa
  # Abonnés des événements du cœur (ADR-003 D7), appelés dans la transaction
  # de l'opération, l'extension active. Interne.
  module Subscriptions
    # `entry.cancelled` (D-SEPA-011) : le règlement d'un paiement est
    # extourné — le paiement redevient à passer et garde la trace de
    # l'écriture annulée. Le fichier émis, lui, ne change pas.
    def self.entry_cancelled(event : Partiduo::Events::Event) : Nil
      entry_id = event["entry_id"].to_i64
      Item.filter(settlement_entry_id: entry_id, settlement: "posted").each do |row|
        row.settlement = "none"
        row.reversed_entry_id = entry_id
        row.settlement_entry_id = nil
        row.save!
      end
    end
  end
end
