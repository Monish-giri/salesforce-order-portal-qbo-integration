@IsTest
private class B2BEarlyPaymentDiscountServiceTest {
    private static Date invoiceDate() {
        return Date.newInstance(2026, 10, 1);
    }

    @IsTest
    static void firstWeekReturnsSevenPercent() {
        B2BEarlyPaymentDiscountService.DiscountResult result =
            B2BEarlyPaymentDiscountService.calculate(
                invoiceDate(),
                invoiceDate().addDays(30),
                invoiceDate().addDays(6),
                10000
            );

        System.assertEquals(7, result.percent);
        System.assertEquals(700, result.amount);
        System.assertEquals(7, result.dayNumber);
        System.assertEquals(true, result.eligible);
    }

    @IsTest
    static void secondWeekReturnsFivePercent() {
        B2BEarlyPaymentDiscountService.DiscountResult result =
            B2BEarlyPaymentDiscountService.calculate(
                invoiceDate(),
                invoiceDate().addDays(30),
                invoiceDate().addDays(13),
                10000
            );

        System.assertEquals(5, result.percent);
        System.assertEquals(500, result.amount);
        System.assertEquals(14, result.dayNumber);
        System.assertEquals(true, result.eligible);
    }

    @IsTest
    static void thirdWeekReturnsTwoPercent() {
        B2BEarlyPaymentDiscountService.DiscountResult result =
            B2BEarlyPaymentDiscountService.calculate(
                invoiceDate(),
                invoiceDate().addDays(30),
                invoiceDate().addDays(20),
                10000
            );

        System.assertEquals(2, result.percent);
        System.assertEquals(200, result.amount);
        System.assertEquals(21, result.dayNumber);
        System.assertEquals(true, result.eligible);
    }

    @IsTest
    static void paymentAfterDueDateGetsNoDiscount() {
        B2BEarlyPaymentDiscountService.DiscountResult result =
            B2BEarlyPaymentDiscountService.calculate(
                invoiceDate(),
                invoiceDate().addDays(30),
                invoiceDate().addDays(31),
                10000
            );

        System.assertEquals(0, result.percent);
        System.assertEquals(0, result.amount);
        System.assertEquals(false, result.eligible);
    }

    @IsTest
    static void invalidInputsGetNoDiscount() {
        B2BEarlyPaymentDiscountService.DiscountResult result =
            B2BEarlyPaymentDiscountService.calculate(
                null,
                invoiceDate().addDays(30),
                invoiceDate().addDays(1),
                10000
            );

        System.assertEquals(0, result.percent);
        System.assertEquals(0, result.amount);
        System.assertEquals(false, result.eligible);
    }
}
