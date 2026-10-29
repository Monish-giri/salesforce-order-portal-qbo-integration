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
            IsActive = true,
            Stock_Quantity__c = 1000,
            Minimum_Wholesale_Quantity__c = 10
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
        OrderSubmissionService.testIsPartner = false;

        Test.startTest();
        OrderSubmissionService.CheckoutContext context = OrderSubmissionService.getCheckoutContext();
        Test.stopTest();

        System.assertEquals(false, context.isPartner);
        System.assertEquals(customer.Id, context.defaultOrderAccountId);
        System.assertEquals(customer.Name, context.defaultOrderAccountName);
        System.assertEquals(0, context.customerAccounts.size());
    }

    @IsTest
    static void partnerCheckoutUsesPartnerAccountWithoutCustomerSelection() {
        Account partner = new Account(Name = 'Test Partner Account');
        insert partner;

        Contact contact = new Contact(
            LastName = 'Partner Portal User',
            AccountId = partner.Id,
            Email = 'partner-order-submission-test@example.com'
        );
        insert contact;

        PricebookEntry entry = [SELECT Id FROM PricebookEntry WHERE Pricebook2.Name = 'Order Submission Test Pricebook' LIMIT 1];

        OrderSubmissionService.testActorAccountId = partner.Id;
        OrderSubmissionService.testContactId = contact.Id;
        OrderSubmissionService.testIsPartner = true;
        OrderSubmissionService.testPricebookName = 'Order Submission Test Pricebook';

        Test.startTest();
        OrderSubmissionService.CheckoutContext context = OrderSubmissionService.getCheckoutContext();
        OrderSubmissionService.SubmissionResult result = OrderSubmissionService.submitOrder(
            JSON.serialize(new List<Object>{
                new Map<String, Object>{
                    'pricebookEntryId' => String.valueOf(entry.Id),
                    'quantity' => 25
                }
            }),
            'test-partner-bulk-order',
            null,
            'Invoice'
        );
        Test.stopTest();

        System.assertEquals(true, context.isPartner);
        System.assertEquals(partner.Id, context.defaultOrderAccountId);
        System.assertEquals(partner.Name, context.defaultOrderAccountName);
        System.assertEquals(0, context.customerAccounts.size());
        System.assertEquals(partner.Id, [SELECT AccountId FROM Order WHERE Id = :result.orderId].AccountId);
        System.assertEquals(partner.Id, [SELECT Placed_By_Account__c FROM Order WHERE Id = :result.orderId].Placed_By_Account__c);
        System.assertEquals('Invoice', result.paymentMethod);
    }

    @IsTest
    static void submitsOrderUsingServerSidePricingAndQuantity() {
        Account customer = [SELECT Id, Name FROM Account WHERE Name = 'Test Direct Customer' LIMIT 1];
        Contact contact = [SELECT Id FROM Contact WHERE Email = 'order-submission-test@example.com' LIMIT 1];
        PricebookEntry entry = [SELECT Id, UnitPrice, Pricebook2Id FROM PricebookEntry WHERE Pricebook2.Name = 'Order Submission Test Pricebook' LIMIT 1];

        OrderSubmissionService.testActorAccountId = customer.Id;
        OrderSubmissionService.testContactId = contact.Id;
        OrderSubmissionService.testIsPartner = false;
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
            customer.Id,
            'Online'
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
        OrderSubmissionService.testIsPartner = false;
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
        OrderSubmissionService.testIsPartner = false;
        OrderSubmissionService.testPricebookName = 'Order Submission Test Pricebook';

        Boolean exceptionThrown = false;
        Test.startTest();
        try {
            OrderSubmissionService.submitOrder(
                JSON.serialize(new List<Object>{new Map<String, Object>{'pricebookEntryId' => String.valueOf(entry.Id), 'quantity' => 1}}),
                'test-submission-invalid-payment',
                customer.Id,
                'Invoice'
            );
        } catch (AuraHandledException ex) {
            exceptionThrown = true;
        }
        Test.stopTest();
        System.assert(exceptionThrown, 'Expected B2C invoice-payment rejection.');
    }

    @IsTest
    static void repeatedSubmissionReturnsExistingOrder() {
        Account customer = [SELECT Id FROM Account WHERE Name = 'Test Direct Customer' LIMIT 1];
        Contact contact = [SELECT Id FROM Contact WHERE Email = 'order-submission-test@example.com' LIMIT 1];
        PricebookEntry entry = [SELECT Id FROM PricebookEntry WHERE Pricebook2.Name = 'Order Submission Test Pricebook' LIMIT 1];

        OrderSubmissionService.testActorAccountId = customer.Id;
        OrderSubmissionService.testContactId = contact.Id;
        OrderSubmissionService.testIsPartner = false;
        OrderSubmissionService.testPricebookName = 'Order Submission Test Pricebook';

        String cartJson = JSON.serialize(new List<Object>{
            new Map<String, Object>{'pricebookEntryId' => String.valueOf(entry.Id), 'quantity' => 2}
        });

        Test.startTest();
        OrderSubmissionService.SubmissionResult first = OrderSubmissionService.submitOrder(cartJson, 'test-submission-duplicate', customer.Id, 'Online');
        OrderSubmissionService.SubmissionResult second = OrderSubmissionService.submitOrder(cartJson, 'test-submission-duplicate', customer.Id, 'Online');
        Test.stopTest();

        System.assertEquals(first.orderId, second.orderId);
        System.assertEquals(true, second.alreadySubmitted);
        System.assertEquals('Online', second.paymentMethod);
        System.assertEquals(1, [SELECT COUNT() FROM Order WHERE Submission_Key__c = 'test-submission-duplicate']);
        Product2 stockAfterRetry = [SELECT Stock_Quantity__c FROM Product2 WHERE ProductCode = 'TEST-ORDER-001' LIMIT 1];
        System.assertEquals(998, stockAfterRetry.Stock_Quantity__c);
    }

    @IsTest
    static void partnerOrderEnforcesMinimumWholesaleQuantity() {
        Account partner = new Account(Name = 'Minimum Quantity Partner');
        insert partner;
        Contact contact = new Contact(LastName = 'Partner', AccountId = partner.Id, Email = 'minimum-partner@example.com');
        insert contact;
        PricebookEntry entry = [SELECT Id FROM PricebookEntry WHERE Pricebook2.Name = 'Order Submission Test Pricebook' LIMIT 1];

        OrderSubmissionService.testActorAccountId = partner.Id;
        OrderSubmissionService.testContactId = contact.Id;
        OrderSubmissionService.testIsPartner = true;
        OrderSubmissionService.testPricebookName = 'Order Submission Test Pricebook';

        Boolean exceptionThrown = false;
        Test.startTest();
        try {
            OrderSubmissionService.submitOrder(
                JSON.serialize(new List<Object>{new Map<String, Object>{'pricebookEntryId' => String.valueOf(entry.Id), 'quantity' => 9}}),
                'test-b2b-below-minimum',
                null,
                'Invoice'
            );
        } catch (AuraHandledException ex) {
            exceptionThrown = true;
        }
        Test.stopTest();
        System.assert(exceptionThrown, 'Expected minimum wholesale quantity rejection.');

        System.assertEquals(1000, [SELECT Stock_Quantity__c FROM Product2 WHERE ProductCode = 'TEST-ORDER-001'].Stock_Quantity__c);
        System.assertEquals(0, [SELECT COUNT() FROM Order WHERE Submission_Key__c = 'test-b2b-below-minimum']);
    }

    @IsTest
    static void rejectsOrderWhenStockIsInsufficient() {
        Product2 product = [SELECT Id, Stock_Quantity__c FROM Product2 WHERE ProductCode = 'TEST-ORDER-001' LIMIT 1];
        product.Stock_Quantity__c = 3;
        update product;

        Account customer = [SELECT Id FROM Account WHERE Name = 'Test Direct Customer' LIMIT 1];
        Contact contact = [SELECT Id FROM Contact WHERE Email = 'order-submission-test@example.com' LIMIT 1];
        PricebookEntry entry = [SELECT Id FROM PricebookEntry WHERE Pricebook2.Name = 'Order Submission Test Pricebook' LIMIT 1];

        OrderSubmissionService.testActorAccountId = customer.Id;
        OrderSubmissionService.testContactId = contact.Id;
        OrderSubmissionService.testIsPartner = false;
        OrderSubmissionService.testPricebookName = 'Order Submission Test Pricebook';

        Boolean exceptionThrown = false;
        Test.startTest();
        try {
            OrderSubmissionService.submitOrder(
                JSON.serialize(new List<Object>{new Map<String, Object>{'pricebookEntryId' => String.valueOf(entry.Id), 'quantity' => 4}}),
                'test-insufficient-stock',
                customer.Id,
                'Online'
            );
        } catch (AuraHandledException ex) {
            exceptionThrown = true;
        }
        Test.stopTest();
        System.assert(exceptionThrown, 'Expected insufficient stock rejection.');

        System.assertEquals(3, [SELECT Stock_Quantity__c FROM Product2 WHERE Id = :product.Id].Stock_Quantity__c);
        System.assertEquals(0, [SELECT COUNT() FROM Order WHERE Submission_Key__c = 'test-insufficient-stock']);
    }

    @IsTest
    static void rejectsDifferentAccountForDirectCustomer() {
        Account customer = [SELECT Id FROM Account WHERE Name = 'Test Direct Customer' LIMIT 1];
        Account unrelated = new Account(Name = 'Unrelated Customer');
        insert unrelated;
        Contact contact = [SELECT Id FROM Contact WHERE Email = 'order-submission-test@example.com' LIMIT 1];
        PricebookEntry entry = [SELECT Id FROM PricebookEntry WHERE Pricebook2.Name = 'Order Submission Test Pricebook' LIMIT 1];

        OrderSubmissionService.testActorAccountId = customer.Id;
        OrderSubmissionService.testContactId = contact.Id;
        OrderSubmissionService.testIsPartner = false;
        OrderSubmissionService.testPricebookName = 'Order Submission Test Pricebook';

        Boolean exceptionThrown = false;
        Test.startTest();
        try {
            OrderSubmissionService.submitOrder(
                JSON.serialize(new List<Object>{new Map<String, Object>{'pricebookEntryId' => String.valueOf(entry.Id), 'quantity' => 1}}),
                'test-submission-unauthorized',
                unrelated.Id,
                'Online'
            );
        } catch (AuraHandledException ex) {
            exceptionThrown = true;
        }
        Test.stopTest();
        System.assert(exceptionThrown, 'Expected authorization failure.');
    }
}
