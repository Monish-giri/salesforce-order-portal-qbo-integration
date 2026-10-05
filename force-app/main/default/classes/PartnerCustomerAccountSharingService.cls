public without sharing class PartnerCustomerAccountSharingService {
    private static final String PARTNER_USER_TYPE = 'PowerPartner';
    private static final String ROLE_GROUP_TYPE = 'Role';
    private static final String ACCOUNT_ACCESS_READ = 'Read';
    private static final String MANUAL_ROW_CAUSE = 'Manual';

    @TestVisible
    private static Map<Id, Set<Id>> testPartnerRoleIdsByPartnerAccount;

    @TestVisible
    private static Map<Id, Id> testRoleGroupByRoleId;

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

        Map<Id, Set<Id>> partnerRoleIds = resolvePartnerRoleIds(partnerAccountIds);
        Set<Id> roleIds = new Set<Id>();
        for (Set<Id> roleSet : partnerRoleIds.values()) {
            roleIds.addAll(roleSet);
        }

        Map<Id, Id> roleGroupByRoleId = resolveRoleGroups(roleIds);
        Set<Id> roleGroupIds = new Set<Id>();
        roleGroupIds.addAll(roleGroupByRoleId.values());

        Map<Id, Set<Id>> desiredGroupIdsByAccount = new Map<Id, Set<Id>>();
        for (Account customerAccount : customerAccounts.values()) {
            Set<Id> desiredGroupIds = new Set<Id>();

            if (customerAccount.Partner_Account__c != null) {
                Set<Id> roleSet = partnerRoleIds.get(customerAccount.Partner_Account__c);
                if (roleSet != null) {
                    for (Id roleId : roleSet) {
                        Id groupId = roleGroupByRoleId.get(roleId);
                        if (groupId != null) {
                            desiredGroupIds.add(groupId);
                        }
                    }
                }
            }

            desiredGroupIdsByAccount.put(customerAccount.Id, desiredGroupIds);
        }

        List<AccountShare> existingShares = new List<AccountShare>();
        if (!roleGroupIds.isEmpty()) {
            existingShares = [
                SELECT Id, AccountId, UserOrGroupId, RowCause
                FROM AccountShare
                WHERE AccountId IN :customerAccounts.keySet()
                AND UserOrGroupId IN :roleGroupIds
                AND RowCause = :MANUAL_ROW_CAUSE
                WITH SYSTEM_MODE
            ];
        }

        Set<String> existingKeys = new Set<String>();
        List<AccountShare> sharesToDelete = new List<AccountShare>();

        for (AccountShare existingShare : existingShares) {
            String key = buildShareKey(existingShare.AccountId, existingShare.UserOrGroupId);
            existingKeys.add(key);

            Set<Id> desiredGroups = desiredGroupIdsByAccount.get(existingShare.AccountId);
            if (desiredGroups == null || !desiredGroups.contains(existingShare.UserOrGroupId)) {
                sharesToDelete.add(existingShare);
            }
        }

        List<AccountShare> sharesToInsert = new List<AccountShare>();

        for (Id accountId : desiredGroupIdsByAccount.keySet()) {
            for (Id groupId : desiredGroupIdsByAccount.get(accountId)) {
                String key = buildShareKey(accountId, groupId);

                if (!existingKeys.contains(key)) {
                    sharesToInsert.add(new AccountShare(
                        AccountId = accountId,
                        UserOrGroupId = groupId,
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

    public static void syncForUsers(List<User> users, Map<Id, User> oldMap) {
        Set<Id> userIds = new Set<Id>();
        Set<Id> oldContactIds = new Set<Id>();

        for (User userRecord : users) {
            userIds.add(userRecord.Id);

            if (oldMap != null && oldMap.containsKey(userRecord.Id)) {
                User oldUser = oldMap.get(userRecord.Id);
                if (oldUser.ContactId != null) {
                    oldContactIds.add(oldUser.ContactId);
                }
            }
        }

        if (userIds.isEmpty() && oldContactIds.isEmpty()) {
            return;
        }

        Set<Id> partnerAccountIds = new Set<Id>();

        for (User userRecord : [
            SELECT Id, UserType, IsActive, ContactId, Contact.AccountId
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

        if (!oldContactIds.isEmpty()) {
            for (Contact oldContact : [
                SELECT Id, AccountId
                FROM Contact
                WHERE Id IN :oldContactIds
                WITH SYSTEM_MODE
            ]) {
                User oldUser = findOldUserByContactId(oldMap, oldContact.Id);

                if (oldUser != null &&
                    oldUser.UserType == PARTNER_USER_TYPE &&
                    oldContact.AccountId != null) {
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

    private static User findOldUserByContactId(Map<Id, User> oldMap, Id contactId) {
        if (oldMap == null || contactId == null) {
            return null;
        }

        for (User oldUser : oldMap.values()) {
            if (oldUser.ContactId == contactId) {
                return oldUser;
            }
        }

        return null;
    }

    private static Map<Id, Set<Id>> resolvePartnerRoleIds(Set<Id> partnerAccountIds) {
        Map<Id, Set<Id>> result = new Map<Id, Set<Id>>();

        if (partnerAccountIds == null || partnerAccountIds.isEmpty()) {
            return result;
        }

        if (Test.isRunningTest() && testPartnerRoleIdsByPartnerAccount != null) {
            return testPartnerRoleIdsByPartnerAccount;
        }

        for (User partnerUser : [
            SELECT Id, UserRoleId, Contact.AccountId
            FROM User
            WHERE UserType = :PARTNER_USER_TYPE
            AND UserRoleId != null
            AND Contact.AccountId IN :partnerAccountIds
            WITH SYSTEM_MODE
        ]) {
            Id partnerAccountId = partnerUser.Contact.AccountId;

            if (!result.containsKey(partnerAccountId)) {
                result.put(partnerAccountId, new Set<Id>());
            }

            result.get(partnerAccountId).add(partnerUser.UserRoleId);
        }

        return result;
    }

    private static Map<Id, Id> resolveRoleGroups(Set<Id> roleIds) {
        Map<Id, Id> result = new Map<Id, Id>();

        if (roleIds == null || roleIds.isEmpty()) {
            return result;
        }

        if (Test.isRunningTest() && testRoleGroupByRoleId != null) {
            return testRoleGroupByRoleId;
        }

        for (Group roleGroup : [
            SELECT Id, RelatedId
            FROM Group
            WHERE Type = :ROLE_GROUP_TYPE
            AND RelatedId IN :roleIds
            WITH SYSTEM_MODE
        ]) {
            result.put(roleGroup.RelatedId, roleGroup.Id);
        }

        return result;
    }

    private static String buildShareKey(Id accountId, Id groupId) {
        return String.valueOf(accountId) + ':' + String.valueOf(groupId);
    }
}
