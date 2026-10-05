public without sharing class PartnerCustomerAccountSharingService {
    private static final String PARTNER_USER_TYPE = 'PowerPartner';
    private static final String ACCOUNT_ACCESS_READ = 'Read';
    private static final String MANUAL_ROW_CAUSE = 'Manual';

    @TestVisible
    private static Map<Id, Set<Id>> testPartnerRoleIdsByPartnerAccount;

    public static void syncAccounts(Set<Id> customerAccountIds, Set<Id> affectedPartnerAccountIds) {
        if (customerAccountIds == null || customerAccountIds.isEmpty()) {
            return;
        }

        Map<Id, Account> customerAccounts = new Map<Id, Account>([
            SELECT Id, Partner_Account__c
            FROM Account
            WHERE Id IN :customerAccountIds
            WITH SYSTEM_MODE
        ]);

        if (customerAccounts.isEmpty()) {
            return;
        }

        Set<Id> partnerAccountIds = new Set<Id>();

        for (Account customerAccount : customerAccounts.values()) {
            if (customerAccount.Partner_Account__c != null) {
                partnerAccountIds.add(customerAccount.Partner_Account__c);
            }
        }

        if (affectedPartnerAccountIds != null) {
            partnerAccountIds.addAll(affectedPartnerAccountIds);
        }

        Map<Id, Set<Id>> desiredShareTargetIdsByAccount =
            resolvePartnerShareTargets(customerAccounts, partnerAccountIds);

        Set<String> existingKeys = new Set<String>();
        List<AccountShare> sharesToDelete = new List<AccountShare>();

        List<AccountShare> existingShares = [
            SELECT Id, AccountId, UserOrGroupId, RowCause
            FROM AccountShare
            WHERE AccountId IN :customerAccounts.keySet()
            AND RowCause = :MANUAL_ROW_CAUSE
            WITH SYSTEM_MODE
        ];

        for (AccountShare existingShare : existingShares) {
            String key = buildShareKey(existingShare.AccountId, existingShare.UserOrGroupId);
            existingKeys.add(key);

            // Remove legacy role-group shares. Direct user shares are retained.
            if (existingShare.UserOrGroupId.getSObjectType() == Group.SObjectType) {
                sharesToDelete.add(existingShare);
            }
        }

        List<AccountShare> sharesToInsert = new List<AccountShare>();

        for (Id accountId : desiredShareTargetIdsByAccount.keySet()) {
            for (Id targetId : desiredShareTargetIdsByAccount.get(accountId)) {
                String key = buildShareKey(accountId, targetId);

                if (!existingKeys.contains(key)) {
                    sharesToInsert.add(new AccountShare(
                        AccountId = accountId,
                        UserOrGroupId = targetId,
                        AccountAccessLevel = ACCOUNT_ACCESS_READ,
                        CaseAccessLevel = 'None',
                        OpportunityAccessLevel = 'None',
                        RowCause = MANUAL_ROW_CAUSE
                    ));
                }
            }
        }

        if (!sharesToDelete.isEmpty()) {
            Database.delete(sharesToDelete, AccessLevel.SYSTEM_MODE);
        }

        if (!sharesToInsert.isEmpty()) {
            Database.insert(sharesToInsert, AccessLevel.SYSTEM_MODE);
        }
    }

    @future
    public static void syncForUserIds(Set<Id> userIds, Set<Id> oldContactIds) {
        if ((userIds == null || userIds.isEmpty()) &&
            (oldContactIds == null || oldContactIds.isEmpty())) {
            return;
        }

        Set<Id> partnerAccountIds = new Set<Id>();

        if (userIds != null && !userIds.isEmpty()) {
            for (User userRecord : [
                SELECT Id, UserType, IsActive, Contact.AccountId
                FROM User
                WHERE Id IN :userIds
                WITH SYSTEM_MODE
            ]) {
                if (userRecord.UserType == PARTNER_USER_TYPE &&
                    userRecord.IsActive &&
                    userRecord.Contact != null &&
                    userRecord.Contact.AccountId != null) {
                    partnerAccountIds.add(userRecord.Contact.AccountId);
                }
            }
        }

        if (oldContactIds != null && !oldContactIds.isEmpty()) {
            for (Contact oldContact : [
                SELECT Id, AccountId
                FROM Contact
                WHERE Id IN :oldContactIds
                WITH SYSTEM_MODE
            ]) {
                if (oldContact.AccountId != null) {
                    partnerAccountIds.add(oldContact.AccountId);
                }
            }
        }

        if (partnerAccountIds.isEmpty()) {
            return;
        }

        Set<Id> customerAccountIds = new Set<Id>();

        for (Account customerAccount : [
            SELECT Id
            FROM Account
            WHERE Partner_Account__c IN :partnerAccountIds
            WITH SYSTEM_MODE
        ]) {
            customerAccountIds.add(customerAccount.Id);
        }

        if (!customerAccountIds.isEmpty()) {
            syncAccounts(customerAccountIds, partnerAccountIds);
        }
    }

    private static Map<Id, Set<Id>> resolvePartnerShareTargets(
        Map<Id, Account> customerAccounts,
        Set<Id> partnerAccountIds
    ) {
        Map<Id, Set<Id>> result = new Map<Id, Set<Id>>();

        if (partnerAccountIds == null || partnerAccountIds.isEmpty()) {
            return result;
        }

        Map<Id, Set<Id>> partnerUserIdsByPartnerAccount = new Map<Id, Set<Id>>();

        if (Test.isRunningTest() && testPartnerRoleIdsByPartnerAccount != null) {
            partnerUserIdsByPartnerAccount = testPartnerRoleIdsByPartnerAccount;
        } else {
            for (User partnerUser : [
                SELECT Id, Contact.AccountId
                FROM User
                WHERE UserType = :PARTNER_USER_TYPE
                AND IsActive = true
                AND Contact.AccountId IN :partnerAccountIds
                WITH SYSTEM_MODE
            ]) {
                if (!partnerUserIdsByPartnerAccount.containsKey(partnerUser.Contact.AccountId)) {
                    partnerUserIdsByPartnerAccount.put(
                        partnerUser.Contact.AccountId,
                        new Set<Id>()
                    );
                }

                partnerUserIdsByPartnerAccount
                    .get(partnerUser.Contact.AccountId)
                    .add(partnerUser.Id);
            }
        }

        for (Account customerAccount : customerAccounts.values()) {
            Set<Id> targets = new Set<Id>();

            if (customerAccount.Partner_Account__c != null) {
                Set<Id> userIds =
                    partnerUserIdsByPartnerAccount.get(customerAccount.Partner_Account__c);

                if (userIds != null) {
                    targets.addAll(userIds);
                }
            }

            result.put(customerAccount.Id, targets);
        }

        return result;
    }

    private static String buildShareKey(Id accountId, Id targetId) {
        return String.valueOf(accountId) + ':' + String.valueOf(targetId);
    }
}
