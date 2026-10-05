trigger PartnerCustomerAccountSharing on Account (after insert, after update) {
    Set<Id> accountIds = new Set<Id>();
    Set<Id> affectedPartnerAccountIds = new Set<Id>();

    for (Account accountRecord : Trigger.new) {
        if (accountRecord.Partner_Account__c != null) {
            accountIds.add(accountRecord.Id);
            affectedPartnerAccountIds.add(accountRecord.Partner_Account__c);
        }

        if (Trigger.isUpdate) {
            Account oldAccount = Trigger.oldMap.get(accountRecord.Id);

            if (oldAccount.Partner_Account__c != null) {
                accountIds.add(accountRecord.Id);
                affectedPartnerAccountIds.add(oldAccount.Partner_Account__c);
            }
        }
    }

    if (!accountIds.isEmpty()) {
        PartnerCustomerAccountSharingService.syncAccounts(
            accountIds,
            affectedPartnerAccountIds
        );
    }
}
