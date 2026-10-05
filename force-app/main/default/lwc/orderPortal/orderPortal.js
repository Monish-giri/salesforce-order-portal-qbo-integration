import { LightningElement, wire } from 'lwc';
import USER_ID from '@salesforce/user/Id';
import { getRecord, getFieldValue } from 'lightning/uiRecordApi';
import USER_NAME from '@salesforce/schema/User.Name';

const USER_FIELDS = [USER_NAME];

export default class OrderPortal extends LightningElement {
    activeSection = 'catalog';
    cartItems = [];

    @wire(getRecord, { recordId: USER_ID, fields: USER_FIELDS })
    userRecord;

    get userName() {
        return getFieldValue(this.userRecord?.data, USER_NAME) || 'Portal User';
    }

    get cartCount() {
        return this.cartItems.reduce((total, item) => total + item.quantity, 0);
    }

    get isCatalog() {
        return this.activeSection === 'catalog';
    }

    get sectionTitle() {
        const titles = {
            orders: 'My Orders',
            returns: 'Returns'
        };
        return titles[this.activeSection] || 'Portal';
    }

    get catalogNavClass() {
        return this.navClass('catalog');
    }

    get ordersNavClass() {
        return this.navClass('orders');
    }

    get returnsNavClass() {
        return this.navClass('returns');
    }

    navClass(section) {
        return 'nav-item ' + (this.activeSection === section ? 'active' : '');
    }

    handleNavigation(event) {
        const section = event.currentTarget.dataset.section;
        if (section === 'catalog') {
            this.activeSection = section;
        }
    }

    showCatalog() {
        this.activeSection = 'catalog';
    }

    handleAddToCart(event) {
        const product = event.detail;
        const existing = this.cartItems.find(
            item => item.pricebookEntryId === product.pricebookEntryId
        );

        if (existing) {
            this.cartItems = this.cartItems.map(item =>
                item.pricebookEntryId === product.pricebookEntryId
                    ? { ...item, quantity: item.quantity + 1 }
                    : item
            );
        } else {
            this.cartItems = [...this.cartItems, { ...product, quantity: 1 }];
        }
    }
}
