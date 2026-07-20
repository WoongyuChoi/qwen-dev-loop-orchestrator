package example.rfd;

/** 환불 승인 내역을 실제 지급 대기 상태로 전환한다. */
public class Rfd2001Service {
    private Rfd2001Mapper mapper;
    public void createRefundPayment(String refundDate) {
        mapper.insertRefundPayment(refundDate);
    }
}
