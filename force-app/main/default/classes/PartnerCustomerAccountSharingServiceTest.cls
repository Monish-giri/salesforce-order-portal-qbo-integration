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

    private static void configureTestSharing(
        Id partnerAccountAId,
        Id partnerAccountBId,
        Id groupAId,
        Id groupBId
    ) {
        PartnerCustomerAccountSharingService.testPartnerRoleIdsByPartnerAccount =
            new Map<Id, Set<Id>>{
                partnerAccountAId => new Set<Id>{ partnerAccountAId },
                partnerAccountBId => new Set<Id>{ partnerAccountBId }
            };

        PartnerCustomerAccountSharingService.testRoleGroupByRoleId =
            new Map<Id, Id>{
                partnerAccountAId => groupAId,
                partnerAccountBId => groupBId
            };
    }

    @IsTest
    static void createsReadShareForPartnerRoleGroup() {
        Account customerAccount = [
            SELECT Id, Partner_Account__c
            FROM Account
            WHERE Name = 'Test Partner Customer'
            LIMIT 1
        ];

        Group partnerRoleGroup = new Group(
            Name = 'Test Partner Role Group A',
            Type = 'Regular'
        );
        insert partnerRoleGroup;

        PartnerCustomerAccountSharingService.testPartnerRoleIdsByPartnerAccount =
            new Map<Id, Set<Id>>{
                customerAccount.Partner_Account__c =>
                    new Set<Id>{ customerAccount.Partner_Account__c }
            };

        PartnerCustomerAccountSharingService.testRoleGroupByRoleId =
            new Map<Id, Id>{
                customerAccount.Partner_Account__c => partnerRoleGroup.Id
            };

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
            AND UserOrGroupId = :partnerRoleGroup.Id
            LIMIT 1
        ];

        System.assertEquals(customerAccount.Id, share.AccountId);
        System.assertEquals(partnerRoleGroup.Id, share.UserOrGroupId);
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

        Group partnerRoleGroup = new Group(
            Name = 'Test Partner Role Group Duplicate',
            Type = 'Regular'
        );
        insert partnerRoleGroup;

        PartnerCustomerAccountSharingService.testPartnerRoleIdsByPartnerAccount =
            new Map<Id, Set<Id>>{
                customerAccount.Partner_Account__c =>
                    new Set<Id>{ customerAccount.Partner_Account__c }
            };

        PartnerCustomerAccountSharingService.testRoleGroupByRoleId =
            new Map<Id, Id>{
                customerAccount.Partner_Account__c => partnerRoleGroup.Id
            };

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
            AND UserOrGroupId = :partnerRoleGroup.Id
            AND RowCause = 'Manual'
        ];

        System.assertEquals(1, shareCount);
    }

    @IsTest
    static void removesOldPartnerRoleShareWhenPartnerChanges() {
        Account customerAccount = [
            SELECT Id, Partner_Account__c
            FROM Account
            WHERE Name = 'Test Partner Customer'
            LIMIT 1
        ];

        Id oldPartnerAccountId = customerAccount.Partner_Account__c;

        Account newPartnerAccount = [
            SELECT Id
            FROM Account
            WHERE Name = 'Test Partner B'
            LIMIT 1
        ];

        Group partnerRoleGroupA = new Group(
            Name = 'Test Partner Role Group Old',
            Type = 'Regular'
        );
        Group partnerRoleGroupB = new Group(
            Name = 'Test Partner Role Group New',
            Type = 'Regular'
        );
        insert new List<Group>{ partnerRoleGroupA, partnerRoleGroupB };

        configureTestSharing(
            oldPartnerAccountId,
            newPartnerAccount.Id,
            partnerRoleGroupA.Id,
            partnerRoleGroupB.Id
        );

        Test.startTest();
        PartnerCustomerAccountSharingService.syncAccounts(
            new Set<Id>{ customerAccount.Id },
            new Set<Id>{ oldPartnerAccountId }
        );

        customerAccount.Partner_Account__c = newPartnerAccount.Id;
        update customerAccount;

        PartnerCustomerAccountSharingService.syncAccounts(
            new Set<Id>{ customerAccount.Id },
            new Set<Id>{ oldPartnerAccountId, newPartnerAccount.Id }
        );
        Test.stopTest();

        Integer oldShareCount = [
            SELECT COUNT()
            FROM AccountShare
            WHERE AccountId = :customerAccount.Id
            AND UserOrGroupId = :partnerRoleGroupA.Id
            AND RowCause = 'Manual'
        ];

        Integer newShareCount = [
            SELECT COUNT()
            FROM AccountShare
            WHERE AccountId = :customerAccount.Id
            AND UserOrGroupId = :partnerRoleGroupB.Id
            AND RowCause = 'Manual'
        ];

        System.assertEquals(0, oldShareCount);
        System.assertEquals(1, newShareCount);
    }
}
