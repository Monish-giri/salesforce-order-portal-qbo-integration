@IsTest
private class OrderSubmissionServiceTest {
    @TestSetup
    static void setupData() {
        Account customer = new Account(Name = 'Test Direct Customer');
        insert customer;

        Contact contact = new Contact(
            LastName = 'Portal User',
            AccountId = customer.Id,
            Email = 'order-submission-test@example.com'
        );
        insert contact;

        Pricebook2 pricebook = new Pricebook2(Name = 'Order Submission Test Pricebook', IsActive = true);
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
    static void directCustomerCheckoutContextUsesOwnAccount() {
        Account customer = [SELECT Id, Name, IsPartner FROM Account WHERE Name = 'Test Direct Customer' LIMIT 1];
        Contact contact = [SELECT Id FROM Contact WHERE Email = 'order-submission-test@example.com' LIMIT 1];

        OrderSubmissionService.testActorAccountId = customer.Id;
        OrderSubmissionService.testContactId = contact.Id;

        Test.startTest();
        OrderSubmissionService.CheckoutContext context = OrderSubmissionService.getCheckoutContext();
        Test.stopTest();

        System.assertEquals(false, context.isPartner);
        System.assertEquals(customer.Id, context.defaultOrderAccountId);
        System.assertEquals(customer.Name, context.defaultOrderAccountName);
        System.assertEquals(0, context.customerAccounts.size());
    }

    @IsTest
    static void submitsOrderUsingServerSidePricingAndQuantity() {
        Account customer = [SELECT Id, Name FROM Account WHERE Name = 'Test Direct Customer' LIMIT 1];
        Contact contact = [SELECT Id FROM Contact WHERE Email = 'order-submission-test@example.com' LIMIT 1];
        PricebookEntry entry = [SELECT Id, UnitPrice, Pricebook2Id FROM PricebookEntry WHERE Pricebook2.Name = 'Order Submission Test Pricebook' LIMIT 1];

        OrderSubmissionService.testActorAccountId = customer.Id;
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
        OrderSubmissionService.SubmissionResult result = OrderSubmissionService.submitOrder(
            cartJson,
            'test-submission-001',
            customer.Id
        );
        Test.stopTest();

        System.assertNotEquals(null, result.orderId);
        System.assertEquals(false, result.alreadySubmitted);
        System.assertEquals(500, result.totalAmount);
        System.assertEquals('Online', result.paymentMethod);

        Order createdOrder = [
            SELECT Id, AccountId, Status, Pricebook2Id,
                   Placed_By_Account__c, Placed_By_Contact__c,
                   Submission_Key__c, TotalAmount, Payment_Method__c
            FROM Order
            WHERE Id = :result.orderId
        ];

        System.assertEquals(customer.Id, createdOrder.AccountId);
        System.assertEquals('Activated', createdOrder.Status);
        System.assertEquals(customer.Id, createdOrder.Placed_By_Account__c);
        System.assertEquals(contact.Id, createdOrder.Placed_By_Contact__c);
        System.assertEquals('test-submission-001', createdOrder.Submission_Key__c);
        System.assertEquals('Online', createdOrder.Payment_Method__c);

        OrderItem item = [SELECT Quantity, UnitPrice, PricebookEntryId FROM OrderItem WHERE OrderId = :createdOrder.Id LIMIT 1];
        System.assertEquals(4, item.Quantity);
        System.assertEquals(125, item.UnitPrice);
        System.assertEquals(entry.Id, item.PricebookEntryId);
    }

    @IsTest
    static void directCustomerCanChooseCashOnDelivery() {
        Account customer = [SELECT Id FROM Account WHERE Name = 'Test Direct Customer' LIMIT 1];
        Contact contact = [SELECT Id FROM Contact WHERE Email = 'order-submission-test@example.com' LIMIT 1];
        PricebookEntry entry = [SELECT Id FROM PricebookEntry WHERE Pricebook2.Name = 'Order Submission Test Pricebook' LIMIT 1];

        OrderSubmissionService.testActorAccountId = customer.Id;
        OrderSubmissionService.testContactId = contact.Id;
        OrderSubmissionService.testPricebookName = 'Order Submission Test Pricebook';

        String cartJson = JSON.serialize(new List<Object>{
            new Map<String, Object>{
                'pricebookEntryId' => String.valueOf(entry.Id),
                'quantity' => 1
            }
        });

        Test.startTest();
        OrderSubmissionService.SubmissionResult result = OrderSubmissionService.submitOrder(
            cartJson,
            'test-submission-cod',
            customer.Id,
            'Cash on Delivery'
        );
        Test.stopTest();

        Order createdOrder = [SELECT Payment_Method__c FROM Order WHERE Id = :result.orderId];
        System.assertEquals('Cash on Delivery', result.paymentMethod);
        System.assertEquals('Cash on Delivery', createdOrder.Payment_Method__c);
    }

    @IsTest
    static void directCustomerRejectsInvoicePayment() {
        Account customer = [SELECT Id FROM Account WHERE Name = 'Test Direct Customer' LIMIT 1];
        Contact contact = [SELECT Id FROM Contact WHERE Email = 'order-submission-test@example.com' LIMIT 1];
        PricebookEntry entry = [SELECT Id FROM PricebookEntry WHERE Pricebook2.Name = 'Order Submission Test Pricebook' LIMIT 1];

        OrderSubmissionService.testActorAccountId = customer.Id;
        OrderSubmissionService.testContactId = contact.Id;
        OrderSubmissionService.testPricebookName = 'Order Submission Test Pricebook';

        Test.startTest();
        try {
            OrderSubmissionService.submitOrder(
                JSON.serialize(new List<Object>{new Map<String, Object>{'pricebookEntryId' => String.valueOf(entry.Id), 'quantity' => 1}}),
                'test-submission-invalid-payment',
                customer.Id,
                'Invoice'
            );
            System.assert(false, 'Expected B2C invoice-payment rejection.');
        } catch (AuraHandledException ex) {
            System.assert(ex.getMessage().contains('B2C orders can only use Online payment or Cash on Delivery'));
        }
        Test.stopTest();
    }

    @IsTest
    static void repeatedSubmissionReturnsExistingOrder() {
        Account customer = [SELECT Id FROM Account WHERE Name = 'Test Direct Customer' LIMIT 1];
        Contact contact = [SELECT Id FROM Contact WHERE Email = 'order-submission-test@example.com' LIMIT 1];
        PricebookEntry entry = [SELECT Id FROM PricebookEntry WHERE Pricebook2.Name = 'Order Submission Test Pricebook' LIMIT 1];

        OrderSubmissionService.testActorAccountId = customer.Id;
        OrderSubmissionService.testContactId = contact.Id;
        OrderSubmissionService.testPricebookName = 'Order Submission Test Pricebook';

        String cartJson = JSON.serialize(new List<Object>{
            new Map<String, Object>{'pricebookEntryId' => String.valueOf(entry.Id), 'quantity' => 2}
        });

        Test.startTest();
        OrderSubmissionService.SubmissionResult first = OrderSubmissionService.submitOrder(cartJson, 'test-submission-duplicate', customer.Id);
        OrderSubmissionService.SubmissionResult second = OrderSubmissionService.submitOrder(cartJson, 'test-submission-duplicate', customer.Id);
        Test.stopTest();

        System.assertEquals(first.orderId, second.orderId);
        System.assertEquals(true, second.alreadySubmitted);
        System.assertEquals('Online', second.paymentMethod);
        System.assertEquals(1, [SELECT COUNT() FROM Order WHERE Submission_Key__c = 'test-submission-duplicate']);
    }

    @IsTest
    static void rejectsDifferentAccountForDirectCustomer() {
        Account customer = [SELECT Id FROM Account WHERE Name = 'Test Direct Customer' LIMIT 1];
        Account unrelated = new Account(Name = 'Unrelated Customer');
        insert unrelated;
        Contact contact = [SELECT Id FROM Contact WHERE Email = 'order-submission-test@example.com' LIMIT 1];

        OrderSubmissionService.testActorAccountId = customer.Id;
        OrderSubmissionService.testContactId = contact.Id;
        OrderSubmissionService.testPricebookName = 'Order Submission Test Pricebook';

        Test.startTest();
        try {
            OrderSubmissionService.submitOrder(
                JSON.serialize(new List<Object>{new Map<String, Object>{'pricebookEntryId' => '01u000000000000AAA', 'quantity' => 1}}),
                'test-submission-unauthorized',
                unrelated.Id
            );
            System.assert(false, 'Expected authorization failure.');
        } catch (AuraHandledException ex) {
            System.assert(ex.getMessage().contains('own account'));
        }
        Test.stopTest();
    }
}
