@IsTest
private class OrderSubmissionServiceTest {
    @TestSetup
    static void setupData() {
        Account partner = new Account(
            Name = 'Test Partner',
            IsPartner = true
        );
        insert partner;

        Account customer = new Account(
            Name = 'Test Customer',
            IsPartner = false,
            Partner_Account__c = partner.Id
        );
        insert customer;

        Contact contact = new Contact(
            LastName = 'Portal User',
            AccountId = partner.Id,
            Email = 'order-submission-test@example.com'
        );
        insert contact;

        Pricebook2 pricebook = new Pricebook2(
            Name = 'Order Submission Test Pricebook',
            IsActive = true
        );
        insert pricebook;

        Product2 product = new Product2(
            Name = 'Test Product',
            ProductCode = 'TEST-ORDER-001',
            IsActive = true
        );
        insert product;

        PricebookEntry standardEntry = new PricebookEntry(
            Pricebook2Id = Test.getStandardPricebookId(),
            Product2Id = product.Id,
            UnitPrice = 100,
            IsActive = true
        );
        insert standardEntry;

        PricebookEntry testEntry = new PricebookEntry(
            Pricebook2Id = pricebook.Id,
            Product2Id = product.Id,
            UnitPrice = 125,
            IsActive = true
        );
        insert testEntry;
    }

    @IsTest
    static void partnerCanSeeAuthorizedCustomers() {
        Account partner = [
            SELECT Id, Name, IsPartner
            FROM Account
            WHERE Name = 'Test Partner'
            LIMIT 1
        ];
        Contact contact = [
            SELECT Id
            FROM Contact
            WHERE Email = 'order-submission-test@example.com'
            LIMIT 1
        ];

        OrderSubmissionService.testActorAccountId = partner.Id;
        OrderSubmissionService.testContactId = contact.Id;

        Test.startTest();
        OrderSubmissionService.CheckoutContext context =
            OrderSubmissionService.getCheckoutContext();
        Test.stopTest();

        System.assertEquals(true, context.isPartner);
        System.assertEquals(1, context.customerAccounts.size());
        System.assertEquals(
            'Test Customer',
            context.customerAccounts[0].name
        );
        System.assertEquals(
            context.customerAccounts[0].id,
            context.defaultOrderAccountId
        );
    }

    @IsTest
    static void submitsOrderUsingServerSidePricingAndQuantity() {
        Account partner = [
            SELECT Id
            FROM Account
            WHERE Name = 'Test Partner'
            LIMIT 1
        ];
        Account customer = [
            SELECT Id, Name
            FROM Account
            WHERE Name = 'Test Customer'
            LIMIT 1
        ];
        Contact contact = [
            SELECT Id
            FROM Contact
            WHERE Email = 'order-submission-test@example.com'
            LIMIT 1
        ];
        PricebookEntry entry = [
            SELECT Id, UnitPrice
            FROM PricebookEntry
            WHERE Pricebook2.Name = 'Order Submission Test Pricebook'
            LIMIT 1
        ];

        OrderSubmissionService.testActorAccountId = partner.Id;
        OrderSubmissionService.testContactId = contact.Id;
        OrderSubmissionService.testPricebookName = 'Order Submission Test Pricebook';

        String cartJson = JSON.serialize(new List<Object>{
            new Map<String, Object>{
                'pricebookEntryId' => String.valueOf(entry.Id),
                'quantity' => 4,
                'unitPrice' => 1
            }
        });

        Test.startTest();
        OrderSubmissionService.SubmissionResult result =
            OrderSubmissionService.submitOrder(
                cartJson,
                'test-submission-001',
                customer.Id
            );
        Test.stopTest();

        System.assertNotEquals(null, result.orderId);
        System.assertEquals(false, result.alreadySubmitted);
        System.assertEquals(500, result.totalAmount);

        Order createdOrder = [
            SELECT Id, AccountId, Status, Pricebook2Id,
                   Placed_By_Account__c, Placed_By_Contact__c,
                   Submission_Key__c, TotalAmount
            FROM Order
            WHERE Id = :result.orderId
        ];

        System.assertEquals(customer.Id, createdOrder.AccountId);
        System.assertEquals('Activated', createdOrder.Status);
        System.assertEquals(partner.Id, createdOrder.Placed_By_Account__c);
        System.assertEquals(contact.Id, createdOrder.Placed_By_Contact__c);
        System.assertEquals('test-submission-001', createdOrder.Submission_Key__c);

        OrderItem item = [
            SELECT Quantity, UnitPrice, PricebookEntryId
            FROM OrderItem
            WHERE OrderId = :createdOrder.Id
            LIMIT 1
        ];

        System.assertEquals(4, item.Quantity);
        System.assertEquals(125, item.UnitPrice);
        System.assertEquals(entry.Id, item.PricebookEntryId);
    }

    @IsTest
    static void repeatedSubmissionReturnsExistingOrder() {
        Account partner = [
            SELECT Id
            FROM Account
            WHERE Name = 'Test Partner'
            LIMIT 1
        ];
        Account customer = [
            SELECT Id
            FROM Account
            WHERE Name = 'Test Customer'
            LIMIT 1
        ];
        Contact contact = [
            SELECT Id
            FROM Contact
            WHERE Email = 'order-submission-test@example.com'
            LIMIT 1
        ];
        PricebookEntry entry = [
            SELECT Id
            FROM PricebookEntry
            WHERE Pricebook2.Name = 'Order Submission Test Pricebook'
            LIMIT 1
        ];

        OrderSubmissionService.testActorAccountId = partner.Id;
        OrderSubmissionService.testContactId = contact.Id;
        OrderSubmissionService.testPricebookName = 'Order Submission Test Pricebook';

        String cartJson = JSON.serialize(new List<Object>{
            new Map<String, Object>{
                'pricebookEntryId' => String.valueOf(entry.Id),
                'quantity' => 2
            }
        });

        Test.startTest();
        OrderSubmissionService.SubmissionResult first =
            OrderSubmissionService.submitOrder(
                cartJson,
                'test-submission-duplicate',
                customer.Id
            );

        OrderSubmissionService.SubmissionResult second =
            OrderSubmissionService.submitOrder(
                cartJson,
                'test-submission-duplicate',
                customer.Id
            );
        Test.stopTest();

        System.assertEquals(first.orderId, second.orderId);
        System.assertEquals(true, second.alreadySubmitted);

        System.assertEquals(
            1,
            [SELECT COUNT() FROM Order WHERE Submission_Key__c = 'test-submission-duplicate']
        );
    }

    @IsTest
    static void rejectsUnauthorizedCustomer() {
        Account partner = [
            SELECT Id
            FROM Account
            WHERE Name = 'Test Partner'
            LIMIT 1
        ];
        Contact contact = [
            SELECT Id
            FROM Contact
            WHERE Email = 'order-submission-test@example.com'
            LIMIT 1
        ];
        Account unrelated = new Account(
            Name = 'Unrelated Customer',
            IsPartner = false
        );
        insert unrelated;

        OrderSubmissionService.testActorAccountId = partner.Id;
        OrderSubmissionService.testContactId = contact.Id;
        OrderSubmissionService.testPricebookName = 'Order Submission Test Pricebook';

        Test.startTest();
        try {
            OrderSubmissionService.submitOrder(
                JSON.serialize(new List<Object>{
                    new Map<String, Object>{
                        'pricebookEntryId' => '01u000000000000AAA',
                        'quantity' => 1
                    }
                }),
                'test-submission-unauthorized',
                unrelated.Id
            );
            System.assert(false, 'Expected authorization failure.');
        } catch (AuraHandledException ex) {
            System.assert(
                ex.getMessage().contains('not authorized')
                || ex.getMessage().contains('authorized')
            );
        }
        Test.stopTest();
    }
}
