@IsTest
private class OrderSharingServiceTest {

    @IsTest
    static void sharesOrderWithPortalUserOnPlacedByAccount() {
        User portalUser = [
            SELECT Id, ContactId, Contact.AccountId, Profile.Name
            FROM User
            WHERE IsActive = true
            AND ContactId != null
            AND Profile.Name = 'Portal Customer'
            LIMIT 1
        ];

        System.assertNotEquals(null, portalUser.Contact.AccountId);

        Pricebook2 standardPricebook = [
            SELECT Id
            FROM Pricebook2
            WHERE IsStandard = true
            LIMIT 1
        ];

        Order testOrder = new Order(
            AccountId = portalUser.Contact.AccountId,
            Placed_By_Account__c = portalUser.Contact.AccountId,
            Placed_By_Contact__c = portalUser.ContactId,
            EffectiveDate = Date.today(),
            Status = 'Draft',
            Pricebook2Id = standardPricebook.Id
        );

        Test.startTest();
        insert testOrder;
        Test.stopTest();

        OrderShare createdShare = [
            SELECT OrderId, UserOrGroupId, OrderAccessLevel, RowCause
            FROM OrderShare
            WHERE OrderId = :testOrder.Id
            AND UserOrGroupId = :portalUser.Id
            LIMIT 1
        ];

        System.assertEquals(testOrder.Id, createdShare.OrderId);
        System.assertEquals(portalUser.Id, createdShare.UserOrGroupId);
        System.assertEquals('Read', createdShare.OrderAccessLevel);
        System.assertEquals('Manual', String.valueOf(createdShare.RowCause));
    }

    @IsTest
    static void doesNotCreateShareWithoutPlacedByAccount() {
        Account accountRecord = new Account(Name = 'Sharing Test Account');
        insert accountRecord;

        Pricebook2 standardPricebook = [
            SELECT Id
            FROM Pricebook2
            WHERE IsStandard = true
            LIMIT 1
        ];

        Order testOrder = new Order(
            AccountId = accountRecord.Id,
            EffectiveDate = Date.today(),
            Status = 'Draft',
            Pricebook2Id = standardPricebook.Id
        );

        Test.startTest();
        insert testOrder;
        Test.stopTest();

        Integer shareCount = [
            SELECT COUNT()
            FROM OrderShare
            WHERE OrderId = :testOrder.Id
        ];

        System.assertEquals(0, shareCount);
    }
}
