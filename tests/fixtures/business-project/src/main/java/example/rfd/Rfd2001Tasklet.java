package example.rfd;

/** 결제 취소 승인 건의 환불 지급 대상을 생성한다. */
public class Rfd2001Tasklet {
    public void execute(String refundDate) {
        new Rfd2001Service().createRefundPayment(refundDate);
    }
}
