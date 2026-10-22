@IsTest
private class RazorpayPaymentServiceTest {
    private class RazorpayOrderMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest request) {
            System.assertEquals('POST', request.getMethod());
            System.assertEquals('callout:Razorpay_API/v1/orders', request.getEndpoint());

            Map<String, Object> payload = (Map<String, Object>) JSON.deserializeUntyped(request.getBody());
            System.assertEquals(930000, Integer.valueOf(String.valueOf(payload.get('amount'))));
            System.assertEquals('INR', String.valueOf(payload.get('currency')));

            HttpResponse response = new HttpResponse();
            response.setStatusCode(200);
            response.setHeader('Content-Type', 'application/json');
            response.setBody('{"id":"order_test_123","amount":930000,"currency":"INR","receipt":"SF-000001"}');
            return response;
        }
    }

    @IsTest
    static void createsDiscountedRazorpayOrder() {
        Account accountRecord = new Account(Name = 'Razorpay Test Account');
        insert accountRecord;

        Id standardPricebookId = Test.getStandardPricebookId();
        Product2 product = new Product2(Name = 'Razorpay Test Product', IsActive = true);
        insert product;

        PricebookEntry entry = new PricebookEntry(
            Pricebook2Id = standardPricebookId,
            Product2Id = product.Id,
            UnitPrice = 10000,
            IsActive = true
        );
        insert entry;

        Order orderRecord = new Order(
            AccountId = accountRecord.Id,
            EffectiveDate = Date.today().addDays(-5),
            Status = 'Draft',
            Pricebook2Id = standardPricebookId,
            Payment_Method__c = 'Invoice',
            QBO_Invoice_Id__c = 'QBO-INV-TEST',
            QBO_Invoice_Number__c = 'SO-000001',
            Invoice_Issue_Date__c = Date.today().addDays(-5),
            Invoice_Due_Date__c = Date.today().addDays(25),
            Invoice_Balance__c = 10000
        );
        insert orderRecord;

        insert new OrderItem(
            OrderId = orderRecord.Id,
            PricebookEntryId = entry.Id,
            Quantity = 1,
            UnitPrice = 10000
        );

        Test.setMock(HttpCalloutMock.class, new RazorpayOrderMock());
        Test.startTest();
        RazorpayPaymentService.PaymentOrderResult result =
            RazorpayPaymentService.createPaymentOrder(orderRecord.Id);
        Test.stopTest();

        System.assertEquals('order_test_123', result.razorpayOrderId);
        System.assertEquals(930000, result.amountPaise);
        System.assertEquals(9300, result.amount);
        System.assertEquals(7, result.discountPercent);
        System.assertEquals(700, result.discountAmount);

        Order updatedOrder = [
            SELECT Razorpay_Order_Id__c, Payment_Amount__c,
                   Early_Payment_Discount__c, Early_Payment_Discount_Percent__c,
                   Payment_Gateway_Status__c
            FROM Order
            WHERE Id = :orderRecord.Id
        ];

        System.assertEquals('order_test_123', updatedOrder.Razorpay_Order_Id__c);
        System.assertEquals(9300, updatedOrder.Payment_Amount__c);
        System.assertEquals(700, updatedOrder.Early_Payment_Discount__c);
        System.assertEquals(7, updatedOrder.Early_Payment_Discount_Percent__c);
        System.assertEquals('Order Created', updatedOrder.Payment_Gateway_Status__c);
    }

    @IsTest
    static void rejectsOrderWithoutQboInvoice() {
        Account accountRecord = new Account(Name = 'No Invoice Test Account');
        insert accountRecord;

        Order orderRecord = new Order(
            AccountId = accountRecord.Id,
            EffectiveDate = Date.today(),
            Status = 'Draft',
            Pricebook2Id = Test.getStandardPricebookId(),
            Payment_Method__c = 'Invoice',
            Invoice_Balance__c = 1000
        );
        insert orderRecord;

        try {
            RazorpayPaymentService.createPaymentOrder(orderRecord.Id);
            System.assert(false, 'Expected an exception for an order without a QBO invoice.');
        } catch (AuraHandledException ex) {
            System.assert(ex.getMessage().contains('QuickBooks invoice'));
        }
    }
}
