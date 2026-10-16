@IsTest
private class QboReturnRequestServiceTest {
    private static Order createOrder() {
        Account account = new Account(Name = 'QBO Return Test Customer');
        insert account;

        Pricebook2 standardBook = [SELECT Id FROM Pricebook2 WHERE IsStandard = true LIMIT 1];
        Product2 product = new Product2(Name = 'QBO Return Test Item', IsActive = true, QBO_Item_Id__c = '1');
        insert product;
        PricebookEntry entry = new PricebookEntry(
            Pricebook2Id = standardBook.Id,
            Product2Id = product.Id,
            UnitPrice = 100,
            IsActive = true
        );
        insert entry;

        Order orderRecord = new Order(
            AccountId = account.Id,
            EffectiveDate = Date.today(),
            Status = 'Draft',
            Pricebook2Id = standardBook.Id,
            QBO_Invoice_Id__c = '145',
            Invoice_Status__c = 'Invoiced'
        );
        insert orderRecord;

        insert new OrderItem(
            OrderId = orderRecord.Id,
            PricebookEntryId = entry.Id,
            Quantity = 5,
            UnitPrice = 100
        );
        return orderRecord;
    }

    @IsTest
    static void createsReturnRequestWithValidatedQuantity() {
        Order orderRecord = createOrder();
        OrderItem item = [SELECT Id FROM OrderItem WHERE OrderId = :orderRecord.Id LIMIT 1];

        Test.startTest();
        Id requestId = QboReturnRequestService.createReturnRequest(
            orderRecord.Id,
            new Map<Id, Decimal>{ item.Id => 2 },
            'Customer returned two items',
            'Applied to Invoice'
        );
        Test.stopTest();

        Return_Request__c request = [
            SELECT Id, Order__c, Status__c, Current_Step__c, Resolution_Type__c
            FROM Return_Request__c WHERE Id = :requestId
        ];
        System.assertEquals(orderRecord.Id, request.Order__c);
        System.assertEquals('Requested', request.Status__c);
        System.assertEquals('Pending', request.Current_Step__c);
        System.assertEquals('Applied to Invoice', request.Resolution_Type__c);

        Return_Request_Line__c line = [
            SELECT Quantity__c, Unit_Price__c, Line_Amount__c, Order_Item__c
            FROM Return_Request_Line__c WHERE Return_Request__c = :requestId LIMIT 1
        ];
        System.assertEquals(2, line.Quantity__c);
        System.assertEquals(100, line.Unit_Price__c);
        System.assertEquals(200, line.Line_Amount__c);
        System.assertEquals(item.Id, line.Order_Item__c);
    }

    @IsTest
    static void rejectsReturnAboveRemainingQuantity() {
        Order orderRecord = createOrder();
        OrderItem item = [SELECT Id FROM OrderItem WHERE OrderId = :orderRecord.Id LIMIT 1];

        Boolean failed = false;
        try {
            QboReturnRequestService.createReturnRequest(
                orderRecord.Id,
                new Map<Id, Decimal>{ item.Id => 6 },
                'Too many',
                'Applied to Invoice'
            );
        } catch (QboReturnRequestService.ReturnRequestException ex) {
            failed = true;
        }
        System.assertEquals(true, failed);
    }
}
