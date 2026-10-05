@IsTest
private class PartnerCustomerAccountSharingServiceTest {
    @TestSetup
    static void setupData() {
        Account partnerAccountA = new Account(Name = 'Test Partner A');
        Account partnerAccountB = new Account(Name = 'Test Partner B');
        insert new List<Account>{ partnerAccountA, partnerAccountB };

        Account customerAccount = new Account(
            Name = 'Test Partner Customer',
            Partner_Account__c = partnerAccountA.Id
        );
        insert customerAccount;
    }

    private static void configureTestSharing(Id partnerAccountAId, Id partnerAccountBId) {
        Id currentUserId = UserInfo.getUserId();

        PartnerCustomerAccountSharingService.testPartnerRoleIdsByPartnerAccount =
            new Map<Id, Set<Id>>{
                partnerAccountAId => new Set<Id>{ currentUserId },
                partnerAccountBId => new Set<Id>{ currentUserId }
            };
    }

    @IsTest
    static void createsReadShareForPartnerUser() {
        Account customerAccount = [
            SELECT Id, Partner_Account__c
            FROM Account
            WHERE Name = 'Test Partner Customer'
            LIMIT 1
        ];

        configureTestSharing(customerAccount.Partner_Account__c, customerAccount.Partner_Account__c);

        Test.startTest();
        PartnerCustomerAccountSharingService.syncAccounts(
            new Set<Id>{ customerAccount.Id },
            new Set<Id>{ customerAccount.Partner_Account__c }
        );
        Test.stopTest();

        AccountShare share = [
            SELECT Id, AccountId, UserOrGroupId, AccountAccessLevel, RowCause
            FROM AccountShare
            WHERE AccountId = :customerAccount.Id
            AND UserOrGroupId = :UserInfo.getUserId()
            AND RowCause = 'Manual'
            LIMIT 1
        ];

        System.assertEquals(customerAccount.Id, share.AccountId);
        System.assertEquals(UserInfo.getUserId(), share.UserOrGroupId);
        System.assertEquals('Read', share.AccountAccessLevel);
        System.assertEquals('Manual', String.valueOf(share.RowCause));
    }

    @IsTest
    static void doesNotCreateDuplicateShare() {
        Account customerAccount = [
            SELECT Id, Partner_Account__c
            FROM Account
            WHERE Name = 'Test Partner Customer'
            LIMIT 1
        ];

        configureTestSharing(customerAccount.Partner_Account__c, customerAccount.Partner_Account__c);

        Test.startTest();
        PartnerCustomerAccountSharingService.syncAccounts(
            new Set<Id>{ customerAccount.Id },
            new Set<Id>{ customerAccount.Partner_Account__c }
        );
        PartnerCustomerAccountSharingService.syncAccounts(
            new Set<Id>{ customerAccount.Id },
            new Set<Id>{ customerAccount.Partner_Account__c }
        );
        Test.stopTest();

        Integer shareCount = [
            SELECT COUNT()
            FROM AccountShare
            WHERE AccountId = :customerAccount.Id
            AND UserOrGroupId = :UserInfo.getUserId()
            AND RowCause = 'Manual'
        ];

        System.assertEquals(1, shareCount);
    }

    @IsTest
    static void removesLegacyRoleGroupShare() {
        Account customerAccount = [
            SELECT Id, Partner_Account__c
            FROM Account
            WHERE Name = 'Test Partner Customer'
            LIMIT 1
        ];

        Group legacyRoleGroup = new Group(
            Name = 'Test Legacy Partner Role Group',
            Type = 'Regular'
        );
        insert legacyRoleGroup;

        insert new AccountShare(
            AccountId = customerAccount.Id,
            UserOrGroupId = legacyRoleGroup.Id,
            AccountAccessLevel = 'Read',
            CaseAccessLevel = 'None',
            OpportunityAccessLevel = 'None',
            RowCause = 'Manual'
        );

        configureTestSharing(customerAccount.Partner_Account__c, customerAccount.Partner_Account__c);

        Test.startTest();
        PartnerCustomerAccountSharingService.syncAccounts(
            new Set<Id>{ customerAccount.Id },
            new Set<Id>{ customerAccount.Partner_Account__c }
        );
        Test.stopTest();

        Integer legacyShareCount = [
            SELECT COUNT()
            FROM AccountShare
            WHERE AccountId = :customerAccount.Id
            AND UserOrGroupId = :legacyRoleGroup.Id
            AND RowCause = 'Manual'
        ];

        Integer userShareCount = [
            SELECT COUNT()
            FROM AccountShare
            WHERE AccountId = :customerAccount.Id
            AND UserOrGroupId = :UserInfo.getUserId()
            AND RowCause = 'Manual'
        ];

        System.assertEquals(0, legacyShareCount);
        System.assertEquals(1, userShareCount);
    }
}
