@IsTest
private class QboInvoiceJobTest {
    @IsTest
    static void createsInvoiceAndStoresQboFields() {
        Account account = new Account(Name = 'Invoice Test Customer', QBO_Customer_Id__c = '60');
        insert account;

        Product2 product = new Product2(
            Name = 'GenWatt Diesel 10kW',
            ProductCode = 'GC1020',
            IsActive = true,
            QBO_Item_Id__c = '19'
        );
        insert product;

        Id pricebookId = Test.getStandardPricebookId();
        PricebookEntry pbe = new PricebookEntry(
            Pricebook2Id = pricebookId,
            Product2Id = product.Id,
            UnitPrice = 5000,
            IsActive = true
        );
        insert pbe;

        Order order = new Order(
            AccountId = account.Id,
            EffectiveDate = Date.newInstance(2026, 10, 6),
            Status = 'Draft',
            Pricebook2Id = pricebookId
        );
        insert order;

        insert new OrderItem(
            OrderId = order.Id,
            PricebookEntryId = pbe.Id,
            Quantity = 2,
            UnitPrice = 5000
        );

        Test.setMock(HttpCalloutMock.class, new InvoiceCreateMock());

        Test.startTest();
        System.enqueueJob(new QboInvoiceJob(order.Id));
        Test.stopTest();

        Order refreshed = [
            SELECT QBO_Invoice_Id__c, QBO_Invoice_Number__c,
                   Invoice_Total__c, Invoice_Balance__c,
                   Invoice_Due_Date__c, Invoice_Status__c,
                   Payment_Status__c
            FROM Order
            WHERE Id = :order.Id
        ];

        System.assertEquals('101', refreshed.QBO_Invoice_Id__c);
        System.assertEquals('SO-00000102', refreshed.QBO_Invoice_Number__c);
        System.assertEquals(10000, refreshed.Invoice_Total__c);
        System.assertEquals(10000, refreshed.Invoice_Balance__c);
        System.assertEquals(Date.newInstance(2026, 11, 5), refreshed.Invoice_Due_Date__c);
        System.assertEquals('Invoiced', refreshed.Invoice_Status__c);
        System.assertEquals('Unpaid', refreshed.Payment_Status__c);

        System.assertEquals(
            1,
            [
                SELECT COUNT()
                FROM QBO_Sync_Log__c
                WHERE Related_Record_Id__c = :String.valueOf(order.Id)
                AND Status__c = 'Success'
            ]
        );
    }

    private class InvoiceCreateMock implements HttpCalloutMock {
        private Integer count = 0;

        public HttpResponse respond(HttpRequest request) {
            count++;

            if (count == 1) {
                System.assertEquals('GET', request.getMethod());
                System.assert(request.getEndpoint().contains('/query?'));
                System.assert(request.getEndpoint().contains('Invoice'));
                return response(200, '{"QueryResponse":{}}');
            }

            System.assertEquals(2, count);
            System.assertEquals('POST', request.getMethod());
            System.assert(request.getEndpoint().contains('/invoice?'));
            System.assert(request.getEndpoint().contains('requestid='));

            Map<String, Object> body =
                (Map<String, Object>) JSON.deserializeUntyped(request.getBody());

            Map<String, Object> customerRef =
                (Map<String, Object>) body.get('CustomerRef');
            System.assertEquals('60', String.valueOf(customerRef.get('value')));
            System.assert(
                String.valueOf(body.get('DocNumber')).startsWith('SO-')
            );

            List<Object> lines = (List<Object>) body.get('Line');
            System.assertEquals(1, lines.size());

            Map<String, Object> line = (Map<String, Object>) lines[0];
            System.assertEquals(
                10000,
                Decimal.valueOf(String.valueOf(line.get('Amount')))
            );

            Map<String, Object> detail =
                (Map<String, Object>) line.get('SalesItemLineDetail');
            Map<String, Object> itemRef =
                (Map<String, Object>) detail.get('ItemRef');

            System.assertEquals('19', String.valueOf(itemRef.get('value')));
            System.assertEquals(2, Decimal.valueOf(String.valueOf(detail.get('Qty'))));
            System.assertEquals(5000, Decimal.valueOf(String.valueOf(detail.get('UnitPrice'))));

            return response(
                200,
                '{"Invoice":{"Id":"101","DocNumber":"SO-00000102","SyncToken":"0","TxnDate":"2026-10-06","DueDate":"2026-11-05","TotalAmt":10000,"Balance":10000}}'
            );
        }
    }

    private static HttpResponse response(Integer code, String body) {
        HttpResponse r = new HttpResponse();
        r.setStatusCode(code);
        r.setStatus('OK');
        r.setHeader('Content-Type', 'application/json');
        r.setBody(body);
        return r;
    }
}
