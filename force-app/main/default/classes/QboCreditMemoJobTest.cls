@IsTest
private class QboCreditMemoJobTest {
    private class ReturnMock implements HttpCalloutMock {
        private final Decimal invoiceBalance;
        private Integer callNumber = 0;

        ReturnMock(Decimal invoiceBalance) {
            this.invoiceBalance = invoiceBalance;
        }

        public HttpResponse respond(HttpRequest request) {
            callNumber++;
            HttpResponse response = new HttpResponse();
            response.setStatusCode(200);
            response.setHeader('Content-Type', 'application/json');
            String endpoint = request.getEndpoint();

            if (endpoint.contains('/query?') && endpoint.contains('CreditMemo')) {
                response.setBody('{"QueryResponse":{}}');
            } else if (endpoint.contains('/refundreceipt')) {
                response.setBody('{"RefundReceipt":{"Id":"701","TotalAmt":100}}');
            } else if (endpoint.contains('/payment')) {
                response.setBody('{"Payment":{"Id":"601","TotalAmt":0}}');
            } else if (endpoint.contains('/creditmemo')) {
                response.setBody('{"CreditMemo":{"Id":"501","DocNumber":"CM-RET-00001"}}');
            } else if (endpoint.contains('/invoice/145')) {
                response.setBody(
                    '{"Invoice":{"Id":"145","TotalAmt":500,"Balance":'
                    + String.valueOf(invoiceBalance)
                    + ',"DueDate":"2026-11-05"}}'
                );
            } else {
                response.setStatusCode(404);
                response.setBody('{"error":"Unexpected test endpoint: ' + endpoint + '"}');
            }
            return response;
        }
    }

    private static Id createReturnRequest(Decimal invoiceBalance, String resolutionType) {
        Account account = new Account(Name = 'QBO Credit Memo Test Customer', QBO_Customer_Id__c = '62');
        insert account;
        Id standardPricebookId = Test.getStandardPricebookId();
        Product2 product = new Product2(Name = 'QBO Credit Memo Item', IsActive = true, QBO_Item_Id__c = '1');
        insert product;
        PricebookEntry entry = new PricebookEntry(Pricebook2Id = standardPricebookId, Product2Id = product.Id, UnitPrice = 100, IsActive = true);
        insert entry;
        Order orderRecord = new Order(
            AccountId = account.Id,
            EffectiveDate = Date.today(),
            Status = 'Draft',
            Pricebook2Id = standardPricebookId,
            QBO_Invoice_Id__c = '145',
            Invoice_Status__c = 'Invoiced',
            Invoice_Total__c = 500,
            Invoice_Balance__c = invoiceBalance,
            Payment_Status__c = invoiceBalance == 0 ? 'Paid' : 'Partially Paid'
        );
        insert orderRecord;
        OrderItem item = new OrderItem(OrderId = orderRecord.Id, PricebookEntryId = entry.Id, Quantity = 2, UnitPrice = 100);
        insert item;
        Return_Request__c request = new Return_Request__c(
            Order__c = orderRecord.Id,
            Status__c = 'Approved',
            Current_Step__c = 'Pending',
            Resolution_Type__c = resolutionType
        );
        // Avoid the approval trigger enqueueing a second job in test setup.
        insert request;
        insert new Return_Request_Line__c(
            Return_Request__c = request.Id,
            Order_Item__c = item.Id,
            Quantity__c = 1,
            Unit_Price__c = 100,
            Tax_Amount__c = 0
        );
        return request.Id;
    }

    @IsTest
    static void appliesCreditMemoToOpenInvoice() {
        Id requestId = createReturnRequest(300, 'Applied to Invoice');
        Test.setMock(HttpCalloutMock.class, new ReturnMock(300));

        Test.startTest();
        System.enqueueJob(new QboCreditMemoJob(requestId));
        Test.stopTest();

        Return_Request__c refreshed = [
            SELECT Status__c, Current_Step__c, QBO_CreditMemo_Id__c, QBO_Payment_Id__c
            FROM Return_Request__c WHERE Id = :requestId
        ];
        System.assertEquals(
            'Credited', refreshed.Status__c,
            'Failure log: ' + getFailureMessage(requestId)
        );
        System.assertEquals('Done', refreshed.Current_Step__c);
        System.assertEquals('501', refreshed.QBO_CreditMemo_Id__c);
        System.assertEquals('601', refreshed.QBO_Payment_Id__c);
    }

    @IsTest
    static void fullyPaidInvoiceUsesRefundPath() {
        Id requestId = createReturnRequest(0, 'Refunded');
        Test.setMock(HttpCalloutMock.class, new ReturnMock(0));

        Test.startTest();
        System.enqueueJob(new QboCreditMemoJob(requestId));
        Test.stopTest();

        Return_Request__c refreshed = [
            SELECT Status__c, Current_Step__c, QBO_CreditMemo_Id__c, QBO_Refund_Id__c
            FROM Return_Request__c WHERE Id = :requestId
        ];
        System.assertEquals(
            'Refunded', refreshed.Status__c,
            'Failure log: ' + getFailureMessage(requestId)
        );
        System.assertEquals('Done', refreshed.Current_Step__c);
        System.assertEquals('501', refreshed.QBO_CreditMemo_Id__c);
        System.assertEquals('701', refreshed.QBO_Refund_Id__c);
    }

    private static String getFailureMessage(Id requestId) {
        List<QBO_Sync_Log__c> logs = [
            SELECT Error_Message__c
            FROM QBO_Sync_Log__c
            WHERE Related_Record_Id__c = :String.valueOf(requestId)
            AND Operation__c = 'Return Processing'
            AND Status__c = 'Failed'
            ORDER BY CreatedDate DESC
            LIMIT 1
        ];
        return logs.isEmpty() ? 'No QBO failure log was created.' : logs[0].Error_Message__c;
    }
}
