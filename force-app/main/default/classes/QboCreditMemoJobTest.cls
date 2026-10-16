@IsTest
private class QboCreditMemoJobTest {
    private class ReturnMock implements HttpCalloutMock {
        private Integer callNumber = 0;

        public HttpResponse respond(HttpRequest request) {
            callNumber++;
            HttpResponse response = new HttpResponse();
            response.setStatusCode(200);
            response.setHeader('Content-Type', 'application/json');
            String endpoint = request.getEndpoint();

            if (endpoint.contains('/query?query=') && endpoint.contains('CreditMemo')) {
                response.setBody('{"QueryResponse":{}}');
            } else if (endpoint.contains('/creditmemo')) {
                response.setBody('{"CreditMemo":{"Id":"501","DocNumber":"CM-RET-00001"}}');
            } else if (endpoint.contains('/payment')) {
                response.setBody('{"Payment":{"Id":"601","TotalAmt":0}}');
            } else if (endpoint.contains('/refundreceipt')) {
                response.setBody('{"RefundReceipt":{"Id":"701","TotalAmt":100}}');
            } else if (endpoint.contains('/invoice/145')) {
                response.setBody(callNumber <= 3
                    ? '{"Invoice":{"Id":"145","TotalAmt":500,"Balance":300,"DueDate":"2026-11-05"}}'
                    : '{"Invoice":{"Id":"145","TotalAmt":500,"Balance":100,"DueDate":"2026-11-05"}}'
                );
            } else {
                response.setBody('{}');
            }
            return response;
        }
    }

    private static Order createOrder(Decimal balance) {
        Account account = new Account(Name = 'QBO Credit Memo Test Customer', QBO_Customer_Id__c = '62');
        insert account;
        Pricebook2 standardBook = [SELECT Id FROM Pricebook2 WHERE IsStandard = true LIMIT 1];
        Product2 product = new Product2(Name = 'QBO Credit Memo Item', IsActive = true, QBO_Item_Id__c = '1');
        insert product;
        PricebookEntry entry = new PricebookEntry(Pricebook2Id = standardBook.Id, Product2Id = product.Id, UnitPrice = 100, IsActive = true);
        insert entry;
        Order orderRecord = new Order(
            AccountId = account.Id,
            EffectiveDate = Date.today(),
            Status = 'Draft',
            Pricebook2Id = standardBook.Id,
            QBO_Invoice_Id__c = '145',
            Invoice_Status__c = 'Invoiced',
            Invoice_Total__c = 500,
            Invoice_Balance__c = balance,
            Payment_Status__c = balance == 0 ? 'Paid' : 'Partially Paid'
        );
        insert orderRecord;
        OrderItem item = new OrderItem(OrderId = orderRecord.Id, PricebookEntryId = entry.Id, Quantity = 2, UnitPrice = 100);
        insert item;
        Return_Request__c request = new Return_Request__c(
            Order__c = orderRecord.Id,
            Status__c = 'Approved',
            Current_Step__c = 'Pending',
            Resolution_Type__c = balance == 0 ? 'Refunded' : 'Applied to Invoice'
        );
        insert request;
        insert new Return_Request_Line__c(
            Return_Request__c = request.Id,
            Order_Item__c = item.Id,
            Quantity__c = 1,
            Unit_Price__c = 100,
            Line_Amount__c = 100,
            Tax_Amount__c = 0
        );
        return orderRecord;
    }

    @IsTest
    static void appliesCreditMemoToOpenInvoice() {
        Order orderRecord = createOrder(300);
        Return_Request__c request = [SELECT Id FROM Return_Request__c WHERE Order__c = :orderRecord.Id LIMIT 1];
        Test.setMock(HttpCalloutMock.class, new ReturnMock());

        Test.startTest();
        System.enqueueJob(new QboCreditMemoJob(request.Id));
        Test.stopTest();

        Return_Request__c refreshed = [SELECT Status__c, Current_Step__c, QBO_CreditMemo_Id__c, QBO_Payment_Id__c FROM Return_Request__c WHERE Id = :request.Id];
        System.assertEquals('Credited', refreshed.Status__c);
        System.assertEquals('Done', refreshed.Current_Step__c);
        System.assertEquals('501', refreshed.QBO_CreditMemo_Id__c);
        System.assertEquals('601', refreshed.QBO_Payment_Id__c);
    }

    @IsTest
    static void fullyPaidInvoiceUsesRefundPath() {
        Order orderRecord = createOrder(0);
        Return_Request__c request = [SELECT Id FROM Return_Request__c WHERE Order__c = :orderRecord.Id LIMIT 1];
        Test.setMock(HttpCalloutMock.class, new ReturnMock());

        Test.startTest();
        System.enqueueJob(new QboCreditMemoJob(request.Id));
        Test.stopTest();

        Return_Request__c refreshed = [SELECT Status__c, Current_Step__c, QBO_CreditMemo_Id__c, QBO_Refund_Id__c FROM Return_Request__c WHERE Id = :request.Id];
        System.assertEquals('Refunded', refreshed.Status__c);
        System.assertEquals('Done', refreshed.Current_Step__c);
        System.assertEquals('501', refreshed.QBO_CreditMemo_Id__c);
        System.assertEquals('701', refreshed.QBO_Refund_Id__c);
    }
}
